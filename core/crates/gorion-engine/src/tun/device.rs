//! Устройство utun на macOS: системный сокет управления
//! `com.apple.net.utun_control`. Каждый пакет на нём начинается с
//! 4 байт семейства адресов (AF_INET или AF_INET6, big-endian).
//! Открыть его может только root — движок в режиме TUN запускает помощник.

use std::ffi::CString;
use std::io;
use std::os::fd::AsRawFd;

use nix::fcntl::{FcntlArg, FdFlag, OFlag, fcntl};
use nix::sys::socket::{
    AddressFamily, SockFlag, SockProtocol, SockType, SysControlAddr, connect, getsockopt, socket,
    sockopt::UtunIfname,
};
use tokio::net::UnixDatagram;

const UTUN_CONTROL: &str = "com.apple.net.utun_control";
/// Заголовок семейства перед каждым пакетом.
pub const PREFIX: usize = 4;
const AF_INET: u8 = 2;
const AF_INET6: u8 = 30;

/// Сокет utun — датаграммный: `recv` отдаёт ровно один пакет, `send`
/// отправляет один. Поэтому его ведёт `UnixDatagram` из tokio (он делает
/// только recv/send и ждёт готовности через kqueue) — без своего unsafe.
pub struct Device {
    socket: UnixDatagram,
    name: String,
}

impl std::fmt::Debug for Device {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Device").field("name", &self.name).finish()
    }
}

impl Device {
    /// Создаёт новый `utunN` (номер выбирает система).
    pub fn open() -> io::Result<Self> {
        let fd = socket(
            AddressFamily::System,
            SockType::Datagram,
            SockFlag::empty(),
            SockProtocol::KextControl,
        )?;
        // Номер 0 — первый свободный utun.
        let address = SysControlAddr::from_name(fd.as_raw_fd(), UTUN_CONTROL, 0)?;
        connect(fd.as_raw_fd(), &address)?;
        let name: CString = getsockopt(&fd, UtunIfname)?;
        let name = name
            .into_string()
            .map_err(|_| io::Error::other("utun: bad interface name"))?;
        let flags = OFlag::from_bits_truncate(fcntl(&fd, FcntlArg::F_GETFL)?);
        fcntl(&fd, FcntlArg::F_SETFL(flags | OFlag::O_NONBLOCK))?;
        fcntl(&fd, FcntlArg::F_SETFD(FdFlag::FD_CLOEXEC))?;
        let socket = std::os::unix::net::UnixDatagram::from(fd);
        Ok(Self {
            socket: UnixDatagram::from_std(socket)?,
            name,
        })
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Читает пакет в `buf` целиком, с 4 байтами семейства впереди.
    pub async fn recv(&self, buf: &mut [u8]) -> io::Result<usize> {
        self.socket.recv(buf).await
    }

    /// Отправляет пакет IP в систему.
    pub async fn send(&self, packet: &[u8]) -> io::Result<()> {
        let family = match packet.first().map(|b| b >> 4) {
            Some(4) => AF_INET,
            Some(6) => AF_INET6,
            _ => return Err(io::Error::from(io::ErrorKind::InvalidInput)),
        };
        let mut framed = Vec::with_capacity(PREFIX + packet.len());
        framed.extend_from_slice(&[0, 0, 0, family]);
        framed.extend_from_slice(packet);
        self.socket.send(&framed).await.map(|_| ())
    }
}
