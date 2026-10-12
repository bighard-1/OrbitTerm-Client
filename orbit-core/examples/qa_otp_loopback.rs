//! Deliberately local-only, non-production SSH MFA fixtures.
//! Run with `cargo run --example qa_otp_loopback -- --mode=password` (default),
//! `--mode=key`, `--mode=jump`, or `--mode=target`. The key mode reads only
//! an ephemeral authorized *public* key path from ORBITTERM_QA_PUBLIC_KEY_PATH.
//! No mode executes shell commands or listens on a non-loopback address. The
//! jump mode forwards only to this fixture's fixed loopback target port.

use std::borrow::Cow;
use std::sync::Arc;
use std::time::Duration;

use russh::keys::{Algorithm, PrivateKey, PublicKey};
use russh::server::{self, Auth, Msg, Response, Server as _, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet, Pty};
use tokio::net::{TcpListener, TcpStream};

const FIXTURE_USER: &str = "qa";
const FIXTURE_PASSWORD: &str = "test-primary";
const PASSWORD_CODE: &[u8] = b"654321";
const KEY_CODE: &[u8] = b"123456";
const JUMP_CODE: &[u8] = b"246810";
const TARGET_CODE: &[u8] = b"135791";
const TARGET_PORT: u32 = 20226;

fn permits_jump_destination(host: &str, port: u32) -> bool {
    matches!(host, "127.0.0.1" | "localhost") && port == TARGET_PORT
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Password,
    Key,
    Jump,
    Target,
}

impl Mode {
    fn from_args() -> Result<Self, Box<dyn std::error::Error>> {
        match std::env::args().nth(1).as_deref() {
            None | Some("--mode=password") => Ok(Self::Password),
            Some("--mode=key") => Ok(Self::Key),
            Some("--mode=jump") => Ok(Self::Jump),
            Some("--mode=target") => Ok(Self::Target),
            _ => Err("expected --mode=password|key|jump|target".into()),
        }
    }

    fn address(self) -> &'static str {
        match self {
            Self::Password => "127.0.0.1:20222",
            Self::Key => "127.0.0.1:20224",
            Self::Jump => "127.0.0.1:20225",
            Self::Target => "127.0.0.1:20226",
        }
    }

    fn code(self) -> &'static [u8] {
        match self {
            Self::Password => PASSWORD_CODE,
            Self::Key => KEY_CODE,
            Self::Jump => JUMP_CODE,
            Self::Target => TARGET_CODE,
        }
    }
}

#[derive(Clone)]
struct Fixture {
    mode: Mode,
    authorized_key: Option<PublicKey>,
    primary_accepted: bool,
}

impl server::Server for Fixture {
    type Handler = Self;

    fn new_client(&mut self, _peer_addr: Option<std::net::SocketAddr>) -> Self {
        Self {
            mode: self.mode,
            authorized_key: self.authorized_key.clone(),
            primary_accepted: false,
        }
    }
}

impl server::Handler for Fixture {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if self.mode == Mode::Key || user != FIXTURE_USER || password != FIXTURE_PASSWORD {
            return Ok(Auth::reject());
        }
        self.primary_accepted = true;
        Ok(Auth::Reject {
            proceed_with_methods: Some(MethodSet::from(&[MethodKind::KeyboardInteractive][..])),
            partial_success: true,
        })
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        public_key: &PublicKey,
    ) -> Result<Auth, Self::Error> {
        if self.mode != Mode::Key
            || user != FIXTURE_USER
            || self.authorized_key.as_ref().map(PublicKey::key_data) != Some(public_key.key_data())
        {
            return Ok(Auth::reject());
        }
        self.primary_accepted = true;
        Ok(Auth::Reject {
            proceed_with_methods: Some(MethodSet::from(&[MethodKind::KeyboardInteractive][..])),
            partial_success: true,
        })
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _submethods: &str,
        response: Option<Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        if user != FIXTURE_USER || !self.primary_accepted {
            return Ok(Auth::reject());
        }
        match response {
            None => Ok(Auth::Partial {
                name: Cow::Borrowed("QA verification"),
                instructions: Cow::Borrowed(""),
                prompts: Cow::Borrowed(&[(Cow::Borrowed("Verification code: "), false)]),
            }),
            Some(mut answers) => Ok(if answers.next().as_deref() == Some(self.mode.code()) {
                Auth::Accept
            } else {
                Auth::reject()
            }),
        }
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host_to_connect: &str,
        port_to_connect: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.mode != Mode::Jump || !permits_jump_destination(host_to_connect, port_to_connect) {
            reply
                .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return Ok(());
        }
        let Ok(mut target) = TcpStream::connect(("127.0.0.1", TARGET_PORT as u16)).await else {
            reply.reject(russh::ChannelOpenFailure::ConnectFailed).await;
            return Ok(());
        };
        reply.accept().await;
        tokio::spawn(async move {
            let mut tunnel = channel.into_stream();
            let _ = tokio::io::copy_bidirectional(&mut tunnel, &mut target).await;
        });
        Ok(())
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        _col_width: u32,
        _row_height: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(
            channel,
            b"OrbitTerm isolated OTP fixture connected. No commands run.\r\n".to_vec(),
        )?;
        Ok(())
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mode = Mode::from_args()?;
    let authorized_key = if mode == Mode::Key {
        let path = std::env::var("ORBITTERM_QA_PUBLIC_KEY_PATH")?;
        Some(PublicKey::from_openssh(&std::fs::read_to_string(path)?)?)
    } else {
        None
    };
    let listener = TcpListener::bind(mode.address()).await?;
    let mut config = server::Config::default();
    config
        .keys
        .push(PrivateKey::random(&mut rand10::rng(), Algorithm::Ed25519)?);
    config.methods = if mode == Mode::Key {
        MethodSet::from(&[MethodKind::PublicKey, MethodKind::KeyboardInteractive][..])
    } else {
        MethodSet::from(&[MethodKind::Password, MethodKind::KeyboardInteractive][..])
    };
    config.auth_rejection_time = Duration::from_millis(1);
    config.inactivity_timeout = Some(Duration::from_secs(120));
    eprintln!(
        "QA OTP {mode:?} fixture listening on {} for at most 20 minutes",
        mode.address()
    );
    match tokio::time::timeout(
        Duration::from_secs(20 * 60),
        Fixture {
            mode,
            authorized_key,
            primary_accepted: false,
        }
        .run_on_socket(Arc::new(config), &listener),
    )
    .await
    {
        Ok(result) => result?,
        Err(_) => eprintln!("QA OTP fixture timed out"),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jump_forwards_only_to_the_fixed_loopback_target() {
        assert!(permits_jump_destination("127.0.0.1", TARGET_PORT));
        assert!(permits_jump_destination("localhost", TARGET_PORT));
        for (host, port) in [
            ("127.0.0.1", 22),
            ("127.0.0.2", TARGET_PORT),
            ("0.0.0.0", TARGET_PORT),
            ("::1", TARGET_PORT),
            ("example.invalid", TARGET_PORT),
        ] {
            assert!(!permits_jump_destination(host, port));
        }
    }

    #[test]
    fn each_mode_uses_a_distinct_loopback_port_and_code() {
        let modes = [Mode::Password, Mode::Key, Mode::Jump, Mode::Target];
        for (index, mode) in modes.iter().enumerate() {
            assert!(mode.address().starts_with("127.0.0.1:"));
            for other in modes.iter().skip(index + 1) {
                assert_ne!(mode.address(), other.address());
                assert_ne!(mode.code(), other.code());
            }
        }
    }
}
