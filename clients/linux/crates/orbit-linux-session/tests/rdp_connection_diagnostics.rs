#![cfg(target_os = "linux")]

use orbit_linux_session::{RdpProfile, RdpSession, SessionEventKind, WorkspacePhase};
use std::env;
use std::fs;
use std::net::TcpListener;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use uuid::Uuid;
use zeroize::Zeroizing;

fn config_directory(label: &str) -> String {
    let path = env::temp_dir().join(format!("orbitterm-{label}-{}", Uuid::new_v4()));
    fs::create_dir_all(&path).expect("create isolated RDP config directory");
    path.to_string_lossy().into_owned()
}

#[test]
fn closed_rdp_port_publishes_a_service_failure_reason() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("reserve closed port");
    let port = listener.local_addr().expect("closed port address").port();
    drop(listener);
    let config_path = config_directory("closed-port");
    let (events, receiver) = mpsc::channel();
    let session = RdpSession::connect(
        Uuid::new_v4(),
        RdpProfile {
            host: "127.0.0.1".into(),
            port,
            username: "diagnostic".into(),
            domain: String::new(),
            config_path: config_path.clone(),
            desktop_width: 1280,
            desktop_height: 720,
            require_nla: true,
        },
        Zeroizing::new("not-a-real-credential".into()),
        events,
    )
    .expect("start isolated RDP diagnostic");

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut failure = None;
    while Instant::now() < deadline {
        let Ok(event) = receiver.recv_timeout(Duration::from_millis(500)) else {
            continue;
        };
        if let SessionEventKind::Failed { code, reason } = event.kind {
            failure = Some((code, reason));
            break;
        }
    }
    session.close();
    drop(session);
    let _ = fs::remove_dir_all(config_path);

    let (code, reason) = failure.expect("closed RDP port must publish a failure");
    assert_ne!(code, 0);
    assert!(
        reason.contains("CONNECT") || reason.contains("TRANSPORT"),
        "unexpected RDP failure classification: {reason}"
    );
}

#[test]
#[ignore = "requires an explicitly authorized live Windows RDP asset"]
fn live_rdp_uses_the_safe_fixed_desktop_and_receives_a_frame() {
    let host = env::var("ORBIT_RDP_TEST_HOST").expect("ORBIT_RDP_TEST_HOST");
    let username = env::var("ORBIT_RDP_TEST_USERNAME").expect("ORBIT_RDP_TEST_USERNAME");
    let password = env::var("ORBIT_RDP_TEST_PASSWORD").expect("ORBIT_RDP_TEST_PASSWORD");
    let port = env::var("ORBIT_RDP_TEST_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(3389);
    let config_path = config_directory("live-fixed-desktop");
    let (events, receiver) = mpsc::channel();
    let session = RdpSession::connect(
        Uuid::new_v4(),
        RdpProfile {
            host,
            port,
            username,
            domain: String::new(),
            config_path: config_path.clone(),
            desktop_width: 1280,
            desktop_height: 720,
            require_nla: true,
        },
        Zeroizing::new(password),
        events,
    )
    .expect("start authorized RDP session");

    let deadline = Instant::now() + Duration::from_secs(30);
    let mut connected = false;
    let mut frame = None;
    while Instant::now() < deadline && frame.is_none() {
        let Ok(event) = receiver.recv_timeout(Duration::from_millis(500)) else {
            continue;
        };
        match event.kind {
            SessionEventKind::RdpCertificate(_) => session
                .certificate_decision(true)
                .expect("accept isolated authorized test certificate"),
            SessionEventKind::Phase(WorkspacePhase::Connected) => connected = true,
            SessionEventKind::RdpFrameReady => {
                if let Some(value) = session.take_frame() {
                    frame = Some((value.width, value.height));
                }
            }
            SessionEventKind::Failed { code, reason } => {
                panic!("authorized RDP session failed: {code} {reason}")
            }
            _ => {}
        }
    }
    session.close();
    drop(session);
    let _ = fs::remove_dir_all(config_path);

    assert!(connected, "authorized RDP target did not connect");
    assert_eq!(frame, Some((1280, 720)));
}
