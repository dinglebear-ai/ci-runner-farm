use std::{
    io,
    net::{SocketAddr, ToSocketAddrs},
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ControllerEndpoint(String);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointError {
    InvalidEndpoint,
    ResolveFailed,
}

impl ControllerEndpoint {
    pub fn parse(value: &str) -> Result<Self, EndpointError> {
        if value.is_empty() || value.len() > 512 || value.chars().any(char::is_whitespace) {
            return Err(EndpointError::InvalidEndpoint);
        }
        if let Ok(address) = value.parse::<SocketAddr>() {
            return if address.port() == 0 {
                Err(EndpointError::InvalidEndpoint)
            } else {
                Ok(Self(value.to_owned()))
            };
        }

        let (host, port) = value
            .rsplit_once(':')
            .ok_or(EndpointError::InvalidEndpoint)?;
        if host.is_empty() || host.len() > 253 || host.starts_with('[') || host.ends_with(']') {
            return Err(EndpointError::InvalidEndpoint);
        }
        let port = port
            .parse::<u16>()
            .ok()
            .filter(|port| *port > 0)
            .ok_or(EndpointError::InvalidEndpoint)?;
        if port == 0 || !valid_dns_name(host) {
            return Err(EndpointError::InvalidEndpoint);
        }
        Ok(Self(value.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn resolve(&self) -> Result<Vec<SocketAddr>, EndpointError> {
        let mut addresses = self
            .0
            .to_socket_addrs()
            .map_err(|_| EndpointError::ResolveFailed)?
            .collect::<Vec<_>>();
        addresses.sort_unstable();
        addresses.dedup();
        if addresses.is_empty() {
            return Err(EndpointError::ResolveFailed);
        }
        Ok(addresses)
    }
}

fn valid_dns_name(host: &str) -> bool {
    if host.ends_with('.') {
        return false;
    }
    host.split('.').all(|label| {
        if label.is_empty() || label.len() > 63 {
            return false;
        }
        let bytes = label.as_bytes();
        bytes.first().is_some_and(u8::is_ascii_alphanumeric)
            && bytes.last().is_some_and(u8::is_ascii_alphanumeric)
            && bytes
                .iter()
                .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-')
    })
}

impl From<ControllerEndpoint> for String {
    fn from(value: ControllerEndpoint) -> Self {
        value.0
    }
}

impl std::fmt::Display for ControllerEndpoint {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::str::FromStr for ControllerEndpoint {
    type Err = EndpointError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl From<EndpointError> for io::Error {
    fn from(error: EndpointError) -> Self {
        let kind = match error {
            EndpointError::InvalidEndpoint => io::ErrorKind::InvalidInput,
            EndpointError::ResolveFailed => io::ErrorKind::AddrNotAvailable,
        };
        io::Error::new(kind, format!("controller endpoint error: {error:?}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_accepts_literal_and_magicdns_shapes() {
        for value in [
            "127.0.0.1:7443",
            "[::1]:7443",
            "controller:7443",
            "controller.tailnet-name.ts.net:7443",
        ] {
            let endpoint = ControllerEndpoint::parse(value).expect("valid endpoint");
            assert_eq!(endpoint.as_str(), value);
        }
    }

    #[test]
    fn endpoint_rejects_urls_unsafe_names_and_zero_ports() {
        for value in [
            "https://controller:7443",
            "controller/path:7443",
            "controller:0",
            "controller:99999",
            "bad_name:7443",
            "-controller:7443",
            "controller-:7443",
            "controller :7443",
        ] {
            assert_eq!(
                ControllerEndpoint::parse(value),
                Err(EndpointError::InvalidEndpoint),
                "{value}"
            );
        }
    }

    #[test]
    fn localhost_hostname_resolves_without_freezing_an_address() {
        let endpoint = ControllerEndpoint::parse("localhost:7443").expect("endpoint");
        let addresses = endpoint.resolve().expect("localhost resolution");
        assert!(!addresses.is_empty());
        assert!(addresses.iter().all(|address| address.port() == 7443));
    }
}
