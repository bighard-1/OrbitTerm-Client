use base64::{engine::general_purpose::STANDARD, Engine as _};

use super::{KnownHostMarker, KnownHostPattern, KnownHostRecord};

pub(super) fn render_record(record: &KnownHostRecord) -> String {
    let marker = match &record.marker {
        KnownHostMarker::None => None,
        KnownHostMarker::Revoked => Some("@revoked".to_string()),
        KnownHostMarker::CertAuthority => Some("@cert-authority".to_string()),
        KnownHostMarker::Unsupported(value) => Some(value.clone()),
    };
    let patterns = record
        .patterns
        .iter()
        .map(render_pattern)
        .collect::<Vec<_>>()
        .join(",");

    let mut fields = Vec::with_capacity(5);
    if let Some(marker) = marker {
        fields.push(marker);
    }
    fields.push(patterns);
    fields.push(record.key_algorithm.clone());
    fields.push(record.public_key_base64.clone());
    if let Some(comment) = record.comment.as_ref().filter(|value| !value.is_empty()) {
        fields.push(comment.clone());
    }
    fields.join(" ")
}

fn render_pattern(pattern: &KnownHostPattern) -> String {
    match pattern {
        KnownHostPattern::Plain(value) | KnownHostPattern::Wildcard(value) => value.clone(),
        KnownHostPattern::Hashed {
            version,
            salt,
            hash,
        } => format!(
            "|{version}|{}|{}",
            STANDARD.encode(salt),
            STANDARD.encode(hash)
        ),
        KnownHostPattern::Negated(inner) => format!("!{}", render_pattern(inner)),
    }
}
