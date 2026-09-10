async fn wait_for_rendezvous(transport: &RelayTransport, count: usize) {
    timeout(Duration::from_secs(2), async {
        loop {
            let ready = transport
                .rendezvous
                .as_ref()
                .is_some_and(|pool| pool.routes.lock().unwrap().clients.len() >= count);
            if ready {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("auxiliary registrations must become ready");
}

async fn receive_rendezvous_data(rx: &mut mpsc::Receiver<RelayMessage>) -> Vec<u8> {
    timeout(Duration::from_secs(2), async {
        loop {
            match rx.recv().await {
                Some(RelayMessage::Data { data, .. }) => return data,
                Some(RelayMessage::Pong { .. }) => {}
                message => panic!("unexpected rendezvous message: {message:?}"),
            }
        }
    })
    .await
    .expect("peer ciphertext must arrive")
}

#[tokio::test]
async fn rendezvous_common_hub_carries_encrypted_round_trip_and_survives_handoff() {
    use p2pnet_crypto::NodeIdentity;
    use p2pnet_wireguard::{HandshakeInitiator, HandshakeResponder, TransportSession};

    let one = RelayServer::start_random().await.unwrap();
    let two = RelayServer::start_random().await.unwrap();
    let common = RelayServer::start_random().await.unwrap();
    let common_endpoint = format!("tcp://{}", common.addr);
    let specs_a = [
        RelayCandidateConfig::legacy(format!("one@tcp://{}", one.addr)),
        RelayCandidateConfig::legacy(format!("common@{common_endpoint}")),
    ];
    let specs_b = [
        RelayCandidateConfig::legacy(format!("two@tcp://{}", two.addr)),
        specs_a[1].clone(),
    ];
    let a = select_relay(
        &specs_a,
        &["one".into()],
        Duration::from_secs(1),
        "a",
        peer_manager(),
        None,
        None,
        true,
        None,
    )
    .await;
    let b = select_relay(
        &specs_b,
        &["two".into()],
        Duration::from_secs(1),
        "b",
        peer_manager(),
        None,
        None,
        true,
        None,
    )
    .await;
    let ta = a.transport.unwrap();
    let tb = b.transport.unwrap();
    let mut ra = a.relay_rx.unwrap();
    let mut rb = b.relay_rx.unwrap();
    assert_ne!(ta.endpoint(), tb.endpoint());
    wait_for_rendezvous(&ta, 2).await;
    wait_for_rendezvous(&tb, 2).await;

    let identity_a = NodeIdentity::generate();
    let identity_b = NodeIdentity::generate();
    let mut initiator = HandshakeInitiator::new(identity_a, identity_b.public_key(), None);
    let mut responder = HandshakeResponder::new(identity_b, None);
    let init = initiator.create_initiation().unwrap();
    let (response, keys_b) = responder.consume_initiation_and_respond(&init).unwrap();
    let mut crypto_a = TransportSession::new(initiator.consume_response(&response).unwrap());
    let mut crypto_b = TransportSession::new(keys_b);
    let writes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let calls = writes.clone();
    let request = b"encrypted request through the shared third relay";
    ta.send_packet_with_write_boundary(
        &EncryptedPeerPacket {
            room_authorization: None,
            peer_id: "b".into(),
            dst_ip: "10.20.0.2".into(),
            wire_bytes: crypto_a.encrypt_to_bytes(request).unwrap(),
            is_business: false,
        },
        move |_| {
            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            true
        },
    )
    .await
    .unwrap();
    let plaintext = crypto_b
        .decrypt_from_bytes(&receive_rendezvous_data(&mut rb).await)
        .unwrap();
    assert_eq!(&plaintext[..request.len()], request);
    assert_eq!(
        writes.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "fanout must install one expectation"
    );

    let reply = b"encrypted reply";
    tb.send_packet(&EncryptedPeerPacket {
        room_authorization: None,
        peer_id: "a".into(),
        dst_ip: "10.20.0.1".into(),
        wire_bytes: crypto_b.encrypt_to_bytes(reply).unwrap(),
        is_business: false,
    })
    .await
    .unwrap();
    let plaintext = crypto_a
        .decrypt_from_bytes(&receive_rendezvous_data(&mut ra).await)
        .unwrap();
    assert_eq!(&plaintext[..reply.len()], reply);
    assert_eq!(
        ta.rendezvous
            .as_ref()
            .unwrap()
            .routes
            .lock()
            .unwrap()
            .peers
            .get("b"),
        Some(&common_endpoint)
    );
    assert_eq!(
        tb.rendezvous
            .as_ref()
            .unwrap()
            .routes
            .lock()
            .unwrap()
            .peers
            .get("a"),
        Some(&common_endpoint)
    );

    // Exercise the exact pool handoff used by primary ticket renewal.
    let retired = Arc::downgrade(ta.rendezvous.as_ref().unwrap());
    let (replacement, rx) = RelayTransport::connect_secure(
        ta.endpoint(),
        ta.region(),
        "a",
        peer_manager(),
        None,
        true,
        None,
    )
    .await
    .unwrap();
    let (replacement, _rx) = ta.handoff_rendezvous(replacement, rx).await;
    drop(ta);
    drop(ra);
    assert!(
        retired.upgrade().is_none(),
        "retired workers must not retain the old pool"
    );
    wait_for_rendezvous(&replacement, 2).await;
    replacement
        .send_packet(&EncryptedPeerPacket {
            room_authorization: None,
            peer_id: "b".into(),
            dst_ip: "10.20.0.2".into(),
            wire_bytes: crypto_a.encrypt_to_bytes(request).unwrap(),
            is_business: true,
        })
        .await
        .unwrap();
    let plaintext = crypto_b
        .decrypt_from_bytes(&receive_rendezvous_data(&mut rb).await)
        .unwrap();
    assert_eq!(&plaintext[..request.len()], request);
    let weak = Arc::downgrade(replacement.rendezvous.as_ref().unwrap());
    drop(replacement);
    assert!(
        weak.upgrade().is_none(),
        "pool ownership must not form a task cycle"
    );
    tb.abort_writer();
    one.shutdown().await;
    two.shutdown().await;
    common.shutdown().await;
}
