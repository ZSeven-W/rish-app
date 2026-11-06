use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const ABI_VERSION: u32 = 1;
pub const PI_VERSION: &str = "1.4.0";
pub const MAX_SCRIPT_BYTES: usize = 32 * 1024;

/// A frozen execution definition. The source is owned user input, not a path
/// or a permission grant. Provider/model selection remains entirely separate.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum RuntimeSpec {
    Pi {
        abi: u32,
        pi_version: String,
    },
    Custom {
        abi: u32,
        pi_version: String,
        name: String,
        source: String,
        sha256: String,
    },
}
impl Default for RuntimeSpec {
    fn default() -> Self {
        Self::pi()
    }
}
impl RuntimeSpec {
    pub fn pi() -> Self {
        Self::Pi {
            abi: ABI_VERSION,
            pi_version: PI_VERSION.into(),
        }
    }
    pub fn custom(name: impl Into<String>, source: impl Into<String>) -> Result<Self, String> {
        let source = source.into();
        let spec = Self::Custom {
            abi: ABI_VERSION,
            pi_version: PI_VERSION.into(),
            name: name.into().trim().to_owned(),
            sha256: script_sha256(&source),
            source,
        };
        spec.validate()?;
        Ok(spec)
    }
    pub fn is_default_pi(&self) -> bool {
        self == &Self::pi()
    }
    pub fn name(&self) -> &str {
        match self {
            Self::Pi { .. } => "Pi",
            Self::Custom { name, .. } => name,
        }
    }
    pub fn source(&self) -> Option<&str> {
        match self {
            Self::Custom { source, .. } => Some(source),
            _ => None,
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        let (abi, version) = match self {
            Self::Pi { abi, pi_version }
            | Self::Custom {
                abi, pi_version, ..
            } => (*abi, pi_version),
        };
        if abi != ABI_VERSION
            || version.len() > 32
            || version.split('.').count() != 3
            || !version
                .split('.')
                .all(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        {
            return Err("E_ASSISTANT_RUNTIME_VERSION".into());
        }
        if let Self::Custom {
            name,
            source,
            sha256,
            ..
        } = self
        {
            if name.is_empty()
                || name.trim() != name
                || name.len() > 256
                || name.chars().any(char::is_control)
                || source.trim().is_empty()
                || source.len() > MAX_SCRIPT_BYTES
                || source.contains('\0')
                || *sha256 != script_sha256(source)
            {
                return Err("E_ASSISTANT_RUNTIME_SCRIPT_INVALID".into());
            }
        }
        Ok(())
    }
    pub fn validate_supported(&self) -> Result<(), String> {
        self.validate()?;
        let version = match self {
            Self::Pi { pi_version, .. } | Self::Custom { pi_version, .. } => pi_version,
        };
        if version != PI_VERSION {
            return Err("E_ASSISTANT_RUNTIME_VERSION_UNAVAILABLE".into());
        }
        Ok(())
    }
}
pub fn script_sha256(source: &str) -> String {
    format!("{:x}", Sha256::digest(source.as_bytes()))
}
