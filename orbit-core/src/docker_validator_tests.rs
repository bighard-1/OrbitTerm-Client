use super::docker_validator::{DockerAction, DockerCommandValidator, DockerValidationError};

const SHORT_ID: &str = "0123456789ab";
const FULL_ID: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

#[test]
fn container_id_accepts_short_and_full_hex_ids() {
    assert!(DockerCommandValidator::validate_container_id(SHORT_ID).is_ok());
    assert!(DockerCommandValidator::validate_container_id(FULL_ID).is_ok());
    assert!(DockerCommandValidator::validate_container_id("ABCDEF012345").is_ok());
}

#[test]
fn container_id_rejects_empty_and_out_of_range_lengths() {
    assert_eq!(
        DockerCommandValidator::validate_container_id("").unwrap_err(),
        DockerValidationError::EmptyContainerId
    );
    assert_eq!(
        DockerCommandValidator::validate_container_id("0123456789a").unwrap_err(),
        DockerValidationError::InvalidContainerIdLength
    );
    assert_eq!(
        DockerCommandValidator::validate_container_id(&"a".repeat(65)).unwrap_err(),
        DockerValidationError::InvalidContainerIdLength
    );
}

#[test]
fn container_id_rejects_shell_syntax_and_non_ascii_input() {
    for input in [
        "0123456789ab ",
        "0123456789ab;id",
        "0123456789ab&&id",
        "0123456789ab&id",
        "0123456789ab|id",
        "0123456789ab>file",
        "0123456789ab<input",
        "0123456789ab$(id)",
        "0123456789ab$id",
        "0123456789ab(id)",
        "0123456789ab`id`",
        "0123456789ab'id'",
        "0123456789ab\"id\"",
        "0123456789ab/id",
        "0123456789ab.id",
        "0123456789ab\n",
        "0123456789ab\u{0007}",
        "0123456789aｂ",
    ] {
        assert!(
            DockerCommandValidator::validate_container_id(input).is_err(),
            "unsafe input was accepted"
        );
    }
}

#[test]
fn action_parser_accepts_only_canonical_enum_values() {
    for (raw, expected) in [
        ("start", DockerAction::Start),
        ("stop", DockerAction::Stop),
        ("restart", DockerAction::Restart),
        ("kill", DockerAction::Kill),
        ("pause", DockerAction::Pause),
        ("unpause", DockerAction::Unpause),
        ("remove", DockerAction::Remove),
        ("START", DockerAction::Start),
    ] {
        assert_eq!(
            DockerCommandValidator::validate_action(raw).unwrap(),
            expected
        );
    }
}

#[test]
fn action_parser_rejects_unknown_compound_and_empty_values() {
    for input in ["", "inspect", "stop;rm -rf /", "rm -f", " start", "start\n"] {
        assert_eq!(
            DockerCommandValidator::validate_action(input).unwrap_err(),
            DockerValidationError::InvalidAction
        );
    }
}

#[test]
fn logs_tail_accepts_bounded_numeric_values() {
    for tail in [0, 100, 10_000] {
        assert!(DockerCommandValidator::validate_logs_options(tail).is_ok());
    }
    assert_eq!(
        DockerCommandValidator::validate_logs_options(10_001).unwrap_err(),
        DockerValidationError::InvalidTail
    );
}

#[test]
fn command_builder_uses_only_validated_container_ids_and_actions() {
    assert_eq!(
        DockerCommandValidator::action_command(SHORT_ID, "restart")
            .unwrap()
            .as_str(),
        "docker restart 0123456789ab"
    );
    assert_eq!(
        DockerCommandValidator::action_command(SHORT_ID, "remove")
            .unwrap()
            .as_str(),
        "docker rm -f 0123456789ab"
    );

    assert!(DockerCommandValidator::action_command("0123456789ab;id", "start").is_err());
    assert!(DockerCommandValidator::action_command(SHORT_ID, "start;id").is_err());
}

#[test]
fn logs_command_uses_numeric_tail_and_preserves_legacy_limits() {
    assert_eq!(
        DockerCommandValidator::logs_command(SHORT_ID, 0)
            .unwrap()
            .as_str(),
        "docker logs --tail 200 0123456789ab 2>&1"
    );
    assert_eq!(
        DockerCommandValidator::logs_command(SHORT_ID, 100)
            .unwrap()
            .as_str(),
        "docker logs --tail 100 0123456789ab 2>&1"
    );
    assert_eq!(
        DockerCommandValidator::logs_command(SHORT_ID, 10_000)
            .unwrap()
            .as_str(),
        "docker logs --tail 2000 0123456789ab 2>&1"
    );
    assert!(DockerCommandValidator::logs_command("0123456789ab;id", 100).is_err());
}

#[test]
fn container_name_uses_a_separate_strict_ascii_grammar() {
    for name in ["web", "web_1", "web.prod", "web-prod"] {
        assert!(DockerCommandValidator::validate_container_name(name).is_ok());
    }
    for name in [
        "", "-web", ".web", "web/name", "web name", "web;id", "web$(id)", "ｗeb",
    ] {
        assert!(DockerCommandValidator::validate_container_name(name).is_err());
    }
    assert!(DockerCommandValidator::validate_container_name(&"a".repeat(128)).is_ok());
    assert!(DockerCommandValidator::validate_container_name(&"a".repeat(129)).is_err());
}

#[test]
fn rename_command_accepts_only_validated_id_and_name() {
    assert_eq!(
        DockerCommandValidator::rename_command(SHORT_ID, "web-prod")
            .unwrap()
            .as_str(),
        "docker rename 0123456789ab web-prod"
    );
    assert!(DockerCommandValidator::rename_command(SHORT_ID, "web;id").is_err());
    assert!(DockerCommandValidator::rename_command("0123456789ab;id", "web").is_err());
}

#[test]
fn update_options_are_allowlisted_and_canonicalized() {
    let options = DockerCommandValidator::validate_update_options(
        Some("unless-stopped"),
        Some("512M"),
        Some(1024),
    )
    .unwrap();
    assert_eq!(
        DockerCommandValidator::update_command(SHORT_ID, options)
            .unwrap()
            .as_str(),
        "docker update --restart unless-stopped --memory 512m --cpu-shares 1024 0123456789ab"
    );

    for policy in ["", "always;id", "on-failure:5", "no --privileged"] {
        assert!(DockerCommandValidator::validate_update_options(Some(policy), None, None).is_err());
    }
    for memory in ["", "0", "01m", "512 mb", "512m;id", "-1g", "1t"] {
        assert!(DockerCommandValidator::validate_update_options(None, Some(memory), None).is_err());
    }
    for shares in [0, 1, 262_145] {
        assert!(DockerCommandValidator::validate_update_options(None, None, Some(shares)).is_err());
    }
    assert!(DockerCommandValidator::validate_update_options(None, None, None).is_err());
}

#[test]
fn validation_errors_have_stable_codes_without_echoing_payloads() {
    for (error, code) in [
        (
            DockerValidationError::EmptyContainerId,
            "empty_container_id",
        ),
        (
            DockerValidationError::InvalidContainerIdLength,
            "invalid_container_id_length",
        ),
        (
            DockerValidationError::InvalidContainerIdCharacter,
            "invalid_container_id_character",
        ),
        (DockerValidationError::InvalidAction, "invalid_action"),
        (DockerValidationError::InvalidTail, "invalid_tail"),
        (
            DockerValidationError::InvalidContainerName,
            "invalid_container_name",
        ),
        (
            DockerValidationError::InvalidRestartPolicy,
            "invalid_restart_policy",
        ),
        (
            DockerValidationError::InvalidMemoryLimit,
            "invalid_memory_limit",
        ),
        (
            DockerValidationError::InvalidCpuShares,
            "invalid_cpu_shares",
        ),
        (
            DockerValidationError::EmptyUpdateOptions,
            "empty_update_options",
        ),
    ] {
        assert_eq!(error.reason_code(), code);
    }

    let attack = "0123456789ab;echo stolen-secret";
    let error = DockerCommandValidator::validate_container_id(attack).unwrap_err();
    assert!(!format!("{error:?}").contains(attack));
    assert!(!error.to_string().contains(attack));
}

#[test]
fn validated_values_and_commands_redact_debug_output() {
    let id = DockerCommandValidator::validate_container_id(SHORT_ID).unwrap();
    let command = DockerCommandValidator::action_command(SHORT_ID, "start").unwrap();

    assert!(!format!("{id:?}").contains(SHORT_ID));
    assert!(!format!("{command:?}").contains(SHORT_ID));
}
