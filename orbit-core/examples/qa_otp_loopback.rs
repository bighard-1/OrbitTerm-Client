//! A deliberately local-only, non-production SSH password + OTP fixture.
//! Run with `cargo run -p orbit-core --example qa_otp_loopback`.
//! It never executes a shell command or listens on a non-loopback address.

use std::borrow::Cow;
use std::sync::Arc;
use std::time::Duration;

use russh::keys::{Algorithm, PrivateKey};
use russh::server::{self, Auth, Msg, Response, Server as _, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet, Pty};
use tokio::net::TcpListener;

const FIXTURE_USER: &str = "qa";
const FIXTURE_PASSWORD: &str = "test-primary";
const FIXTURE_CODE: &[u8] = b"654321";
const LOOPBACK_ADDRESS: &str = "127.0.0.1:20222";

#[derive(Clone, Default)]
struct Fixture {
    password_accepted: bool,
}

impl server::Server for Fixture {
    type Handler = Self;

    fn new_client(&mut self, _peer_addr: Option<std::net::SocketAddr>) -> Self {
        Self::default()
    }
}

impl server::Handler for Fixture {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if user != FIXTURE_USER || password != FIXTURE_PASSWORD {
            return Ok(Auth::reject());
        }
        self.password_accepted = true;
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
        if user != FIXTURE_USER || !self.password_accepted {
            return Ok(Auth::reject());
        }
        match response {
            None => Ok(Auth::Partial {
                name: Cow::Borrowed("QA verification"),
                instructions: Cow::Borrowed(""),
                prompts: Cow::Borrowed(&[(Cow::Borrowed("Verification code: "), false)]),
            }),
            Some(mut answers) => Ok(if answers.next().as_deref() == Some(FIXTURE_CODE) {
                Auth::Accept
            } else {
                Auth::reject()
            }),
        }
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
    let listener = TcpListener::bind(LOOPBACK_ADDRESS).await?;
    let mut config = server::Config::default();
    config
        .keys
        .push(PrivateKey::random(&mut rand10::rng(), Algorithm::Ed25519)?);
    config.methods = MethodSet::from(&[MethodKind::Password, MethodKind::KeyboardInteractive][..]);
    config.auth_rejection_time = Duration::from_millis(1);
    config.inactivity_timeout = Some(Duration::from_secs(120));
    eprintln!("QA OTP fixture listening on {LOOPBACK_ADDRESS} for at most 20 minutes");
    match tokio::time::timeout(
        Duration::from_secs(20 * 60),
        Fixture::default().run_on_socket(Arc::new(config), &listener),
    )
    .await
    {
        Ok(result) => result?,
        Err(_) => eprintln!("QA OTP fixture timed out"),
    }
    Ok(())
}
