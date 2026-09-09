match cmd {
                        ControlCommand::PollPeersNow => {
                            // A signal arrived from a peer that the daemon has
                            // not registered yet: bring the peer list current
                            // immediately instead of waiting out the regular
                            // poll cadence, then re-arm the regular tick so
                            // this does not create a poll burst.
                            peer_roster_tick.reset();
                            let poll_result = async {
                                let current_http = http.current()?;
                                poll_peers(
                                    &current_http,
                                    &base_url,
                                    &token,
                                    &config,
                                    &self_node_id,
                                    registration_seq,
                                    &state,
                                    event_tx,
                                )
                                .await
                            }
                            .await;
                            match &poll_result {
                                Ok(_) => {
                                    poll_failures = 0;
                                    if let Some(health) = health.as_ref() {
                                        health.mark_control_success().await;
                                    }
                                    let _ = event_tx.send(ControlEvent::ControlHealthy);
                                }
                                Err(err) => {
                                    let err_str = err.to_string();
                                    if is_registration_conflict_error(&err_str) {
                                        emit_registration_lifecycle_conflict(health.as_ref(), event_tx, err_str).await;
                                        return;
                                    }
                                    warn!("Immediate peer polling failed: {err_str}");
                                    poll_failures = poll_failures.saturating_add(1);
                                }
                            }
                        }
                        ControlCommand::NetworkChanged => {
                            http.notify_network_changed();
                            if let Some(task) = signal_ws_task.as_ref() {
                                task.abort();
                            }
                            info!("Android physical network changed; restarting control registration and signaling transports");
                            break;
                        }
                        ControlCommand::CreateTunnel { protocol, local_port, remote_port } => {
                            let res = async {
                                let current_http = http.current()?;
                                create_tunnel(
                                    &current_http,
                                    &base_url,
                                    &token,
                                    &self_node_id,
                                    registration_seq,
                                    &protocol,
                                    local_port,
                                    remote_port,
                                )
                                .await
                            }
                            .await;
                            match res {
                                Ok((tunnel_id, public_endpoint)) => {
                                    let _ = event_tx.send(ControlEvent::TunnelCreated { tunnel_id, public_endpoint });
                                }
                                Err(err) => {
                                    let err_str = err.to_string();
                                    if is_registration_conflict_error(&err_str) {
                                        emit_registration_lifecycle_conflict(health.as_ref(), event_tx, err_str).await;
                                        return;
                                    }
                                    let code = if is_permanent_auth_error(&err_str) { 401u16 } else { 3000u16 };
                                    let _ = event_tx.send(ControlEvent::ServerError { code, message: err_str });
                                    if code == 401 {
                                        break;
                                    }
                                }
                            }
                        }
                        ControlCommand::UpdateEndpoint { endpoint, nat_type, response_tx } => {
                            let relay_rtt_ms = current_relay_rtt_ms(relay_selection.as_ref()).await;
                            let published_nat_type = control_label_with_registration_seq(
                                &nat_type,
                                registration_seq,
                            );
                            let res = async {
                                let current_http = http.current()?;
                                update_endpoint(
                                    &current_http,
                                    &base_url,
                                    &token,
                                    &self_node_id,
                                    &endpoint,
                                    &published_nat_type,
                                    relay_rtt_ms,
                                    registration_seq,
                                )
                                .await
                            }
                            .await;
                            match &res {
                                Ok(()) => {
                                    advertised_snapshot
                                        .lock()
                                        .unwrap()
                                        .update(endpoint.clone(), published_nat_type.clone());
                                    debug!("Updated endpoint for {self_node_id}: {endpoint} ({published_nat_type})");
                                    if let Some(health) = health.as_ref() {
                                        health.mark_device_lease_success().await;
                                    }
                                    let _ = event_tx.send(ControlEvent::ControlHealthy);
                                }
                                Err(err) => {
                                    let err_str = err.to_string();
                                    if let Some(health) = health.as_ref() {
                                        // Endpoint PATCH is the server-side
                                        // online lease heartbeat. A failed
                                        // PATCH must remain visible even if a
                                        // later roster/signal GET succeeds.
                                        health.set_device_lease_healthy(false);
                                    }
                                    let _ = event_tx.send(ControlEvent::ServerError { code: 2000, message: err_str.clone() });
                                    if is_permanent_auth_error(&err_str) {
                                        break;
                                    }
                                }
                            }
                            let lifecycle_conflict = res
                                .as_ref()
                                .err()
                                .is_some_and(|err| is_registration_conflict_error(&err.to_string()));
                            let _ = response_tx.send(res);
                            if lifecycle_conflict {
                                emit_registration_lifecycle_conflict(
                                    health.as_ref(),
                                    event_tx,
                                    "endpoint update rejected by the current registration lifecycle".into(),
                                )
                                .await;
                                return;
                            }
                        }
                        ControlCommand::SendPeerReflexive { to_node_id, observed_endpoint, punch_at_ms, response_tx } => {
                            let candidates = vec![observed_endpoint.clone()];
                            let candidate_sources = HashMap::from([
                                (observed_endpoint.clone(), "peer_reflexive".to_string())
                            ]);
                            let res = async {
                                let current_http = http.current()?;
                                send_signal(
                                    &current_http,
                                    &base_url,
                                    &token,
                                    registration_seq,
                                    &self_node_id,
                                    &to_node_id,
                                    "peer_reflexive",
                                    &candidates,
                                    &candidate_sources,
                                    &[],
                                    punch_at_ms,
                                    None,
                                    None,
                                    None,
                                    None,
                                )
                                .await
                            }
                            .await;
                            match &res {
                                Ok(()) => {
                                    debug!(
                                        "Sent peer-reflexive observation to {to_node_id}: {observed_endpoint} punch_at_ms={punch_at_ms:?}"
                                    );
                                }
                                Err(err) => {
                                    let err_str = err.to_string();
                                    let _ = event_tx.send(ControlEvent::ServerError { code: 4002, message: err_str.clone() });
                                    if is_permanent_auth_error(&err_str) {
                                        break;
                                    }
                                }
                            }
                            let lifecycle_conflict = res
                                .as_ref()
                                .err()
                                .is_some_and(|err| is_registration_conflict_error(&err.to_string()));
                            let _ = response_tx.send(res);
                            if lifecycle_conflict {
                                emit_registration_lifecycle_conflict(
                                    health.as_ref(),
                                    event_tx,
                                    "peer-reflexive signal rejected by the current registration lifecycle".into(),
                                )
                                .await;
                                return;
                            }
                        }
                        ControlCommand::DeleteTunnel { tunnel_id } => {
                            debug!("Tunnel deletion queued locally for {tunnel_id}");
                        }
                        ControlCommand::FetchRelayTicket { audience, region, response_tx } => {
                            let result = async {
                                let current_http = http.current()?;
                                fetch_relay_ticket_http(
                                    &current_http,
                                    &base_url,
                                    &token,
                                    registration_seq,
                                    &audience,
                                    &region,
                                )
                                .await
                            }
                            .await;
                            let lifecycle_conflict = result
                                .as_ref()
                                .err()
                                .is_some_and(|err| is_registration_conflict_error(&err.to_string()));
                            let _ = response_tx.send(result);
                            if lifecycle_conflict {
                                emit_registration_lifecycle_conflict(
                                    health.as_ref(),
                                    event_tx,
                                    "relay ticket request rejected by the current registration lifecycle".into(),
                                )
                                .await;
                                return;
                            }
                        }
                        ControlCommand::Shutdown { response_tx } => {
                            let release_result = async {
                                let current_http = http.current()?;
                                release_presence(
                                    &current_http,
                                    &base_url,
                                    &token,
                                    &self_node_id,
                                    registration_seq,
                                )
                                    .await
                            }
                            .await;
                            if let Err(err) = release_result {
                                warn!(
                                    "Best-effort device presence release failed for {}: {}",
                                    self_node_id, err
                                );
                            }
                            let _ = response_tx.send(());
                            let _ = event_tx.send(ControlEvent::Disconnected);
                            return;
                        }
                        ControlCommand::LifecycleConflict { message } => {
                            emit_registration_lifecycle_conflict(health.as_ref(), event_tx, message).await;
                            return;
                        }
                    }
