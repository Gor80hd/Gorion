//! Пакеты IP внутри туннеля: разбор, перезапись адресов TCP (NAT системного
//! стека, как в sing-tun), ответы UDP для DNS и отказы (RST, ICMP).
//!
//! Контрольные суммы считаются заново целиком: пакеты из utun приходят с
//! полными суммами, и полный пересчёт не зависит от того, что поменялось.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;
const PROTO_ICMP: u8 = 1;
const PROTO_ICMPV6: u8 = 58;

const IPV4_HEADER: usize = 20;
const IPV6_HEADER: usize = 40;
const TCP_HEADER: usize = 20;
const UDP_HEADER: usize = 8;
const TTL: u8 = 64;
/// IPv4: «не фрагментировать».
const FLAG_DF: u16 = 0x4000;

const TCP_FIN: u8 = 0x01;
const TCP_SYN: u8 = 0x02;
const TCP_RST: u8 = 0x04;
const TCP_ACK: u8 = 0x10;

/// Минимальный MTU IPv6: ошибка ICMPv6 не должна быть длиннее (RFC 4443).
const IPV6_MIN_MTU: usize = 1280;

/// Заголовок IP и где начинается транспорт.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub protocol: u8,
    pub source: IpAddr,
    pub destination: IpAddr,
    /// Начало заголовка транспорта.
    pub transport: usize,
    /// Конец пакета по длине из заголовка IP.
    pub end: usize,
}

impl Header {
    fn is_v4(&self) -> bool {
        self.source.is_ipv4()
    }

    /// Порты TCP или UDP: (источник, назначение).
    pub fn ports(&self, packet: &[u8]) -> Option<(u16, u16)> {
        let min = match self.protocol {
            PROTO_TCP => TCP_HEADER,
            PROTO_UDP => UDP_HEADER,
            _ => return None,
        };
        if self.transport + min > self.end {
            return None;
        }
        let t = &packet[self.transport..];
        Some((
            u16::from_be_bytes([t[0], t[1]]),
            u16::from_be_bytes([t[2], t[3]]),
        ))
    }

    /// Данные UDP.
    pub fn udp_payload<'a>(&self, packet: &'a [u8]) -> Option<&'a [u8]> {
        if self.protocol != PROTO_UDP || self.transport + UDP_HEADER > self.end {
            return None;
        }
        packet.get(self.transport + UDP_HEADER..self.end)
    }
}

/// Разбирает пакет. `None` — не IP, обрезан, фрагмент или IPv6 с
/// заголовками расширения: такие пакеты туннель отбрасывает.
pub fn parse(packet: &[u8]) -> Option<Header> {
    match packet.first()? >> 4 {
        4 => parse_v4(packet),
        6 => parse_v6(packet),
        _ => None,
    }
}

fn parse_v4(p: &[u8]) -> Option<Header> {
    if p.len() < IPV4_HEADER {
        return None;
    }
    let ihl = usize::from(p[0] & 0x0F) * 4;
    let total = usize::from(u16::from_be_bytes([p[2], p[3]]));
    if ihl < IPV4_HEADER || total < ihl || total > p.len() {
        return None;
    }
    // Фрагменты не собираем: TCP ставит DF, запросы DNS маленькие.
    let fragment = u16::from_be_bytes([p[6], p[7]]);
    if fragment & 0x3FFF != 0 {
        return None;
    }
    Some(Header {
        protocol: p[9],
        source: IpAddr::V4(Ipv4Addr::new(p[12], p[13], p[14], p[15])),
        destination: IpAddr::V4(Ipv4Addr::new(p[16], p[17], p[18], p[19])),
        transport: ihl,
        end: total,
    })
}

fn parse_v6(p: &[u8]) -> Option<Header> {
    if p.len() < IPV6_HEADER {
        return None;
    }
    let end = IPV6_HEADER + usize::from(u16::from_be_bytes([p[4], p[5]]));
    if end > p.len() {
        return None;
    }
    let mut source = [0u8; 16];
    source.copy_from_slice(&p[8..24]);
    let mut destination = [0u8; 16];
    destination.copy_from_slice(&p[24..40]);
    Some(Header {
        protocol: p[6],
        source: IpAddr::V6(Ipv6Addr::from(source)),
        destination: IpAddr::V6(Ipv6Addr::from(destination)),
        transport: IPV6_HEADER,
        end,
    })
}

/// Адрес, который стоит вести через туннель: как `IsGlobalUnicast` в Go
/// (частные сети тоже подходят, групповые и локальные для канала — нет).
pub fn is_routable(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            !(ip.is_unspecified()
                || ip.is_loopback()
                || ip.is_multicast()
                || ip.is_link_local()
                || ip.is_broadcast())
        }
        IpAddr::V6(ip) => {
            let link_local = ip.segments()[0] & 0xFFC0 == 0xFE80;
            !(ip.is_unspecified() || ip.is_loopback() || ip.is_multicast() || link_local)
        }
    }
}

/// Сумма 16-битных слов в дополнительном коде.
fn sum(data: &[u8], mut acc: u64) -> u64 {
    let (words, rest) = data.as_chunks::<2>();
    for word in words {
        acc += u64::from(u16::from_be_bytes(*word));
    }
    if let [last] = rest {
        acc += u64::from(u16::from_be_bytes([*last, 0]));
    }
    acc
}

fn fold(mut acc: u64) -> u16 {
    while acc >> 16 != 0 {
        acc = (acc & 0xFFFF) + (acc >> 16);
    }
    !(acc as u16)
}

fn pseudo_header(source: IpAddr, destination: IpAddr, protocol: u8, len: usize) -> u64 {
    let acc = match (source, destination) {
        (IpAddr::V4(s), IpAddr::V4(d)) => sum(&d.octets(), sum(&s.octets(), 0)),
        (IpAddr::V6(s), IpAddr::V6(d)) => sum(&d.octets(), sum(&s.octets(), 0)),
        _ => 0,
    };
    acc + u64::from(protocol) + len as u64
}

fn set_ipv4_checksum(packet: &mut [u8], header_len: usize) {
    packet[10] = 0;
    packet[11] = 0;
    let checksum = fold(sum(&packet[..header_len], 0));
    packet[10..12].copy_from_slice(&checksum.to_be_bytes());
}

/// Пересчитывает сумму TCP, UDP или ICMP по уже записанным адресам.
fn set_transport_checksum(packet: &mut [u8], header: &Header) {
    let offset = match header.protocol {
        PROTO_TCP => 16,
        PROTO_UDP => 6,
        PROTO_ICMP | PROTO_ICMPV6 => 2,
        _ => return,
    };
    let at = header.transport + offset;
    packet[at] = 0;
    packet[at + 1] = 0;
    let segment = &packet[header.transport..header.end];
    // У ICMPv4 нет псевдозаголовка, у ICMPv6 — есть.
    let start = if header.protocol == PROTO_ICMP {
        0
    } else {
        pseudo_header(
            header.source,
            header.destination,
            header.protocol,
            segment.len(),
        )
    };
    let mut checksum = fold(sum(segment, start));
    if header.protocol == PROTO_UDP && checksum == 0 {
        checksum = 0xFFFF;
    }
    packet[at..at + 2].copy_from_slice(&checksum.to_be_bytes());
}

fn write_addresses(packet: &mut [u8], source: IpAddr, destination: IpAddr) -> bool {
    match (source, destination) {
        (IpAddr::V4(s), IpAddr::V4(d)) if packet.len() >= IPV4_HEADER => {
            packet[12..16].copy_from_slice(&s.octets());
            packet[16..20].copy_from_slice(&d.octets());
            true
        }
        (IpAddr::V6(s), IpAddr::V6(d)) if packet.len() >= IPV6_HEADER => {
            packet[8..24].copy_from_slice(&s.octets());
            packet[24..40].copy_from_slice(&d.octets());
            true
        }
        _ => false,
    }
}

/// Меняет адреса и порты сегмента TCP на месте. `false` — семейства
/// адресов не совпали с пакетом или сегмент обрезан.
pub fn rewrite_tcp(
    packet: &mut [u8],
    header: &Header,
    source: SocketAddr,
    destination: SocketAddr,
) -> bool {
    if header.protocol != PROTO_TCP
        || header.transport + TCP_HEADER > header.end
        || source.is_ipv4() != header.is_v4()
        || destination.is_ipv4() != header.is_v4()
        || !write_addresses(packet, source.ip(), destination.ip())
    {
        return false;
    }
    let t = header.transport;
    packet[t..t + 2].copy_from_slice(&source.port().to_be_bytes());
    packet[t + 2..t + 4].copy_from_slice(&destination.port().to_be_bytes());
    let rewritten = Header {
        source: source.ip(),
        destination: destination.ip(),
        ..*header
    };
    if header.is_v4() {
        set_ipv4_checksum(packet, header.transport);
    }
    set_transport_checksum(packet, &rewritten);
    true
}

/// Пакет IP с готовым сегментом транспорта; суммы посчитаны.
fn build(source: IpAddr, destination: IpAddr, protocol: u8, segment: &[u8]) -> Vec<u8> {
    let mut packet = match (source, destination) {
        (IpAddr::V4(_), IpAddr::V4(_)) => {
            let total = (IPV4_HEADER + segment.len()) as u16;
            let mut p = vec![0u8; IPV4_HEADER];
            p[0] = 0x45;
            p[2..4].copy_from_slice(&total.to_be_bytes());
            p[6..8].copy_from_slice(&FLAG_DF.to_be_bytes());
            p[8] = TTL;
            p[9] = protocol;
            p
        }
        _ => {
            let mut p = vec![0u8; IPV6_HEADER];
            p[0] = 0x60;
            p[4..6].copy_from_slice(&(segment.len() as u16).to_be_bytes());
            p[6] = protocol;
            p[7] = TTL;
            p
        }
    };
    write_addresses(&mut packet, source, destination);
    let transport = packet.len();
    packet.extend_from_slice(segment);
    let header = Header {
        protocol,
        source,
        destination,
        transport,
        end: packet.len(),
    };
    if source.is_ipv4() {
        set_ipv4_checksum(&mut packet, transport);
    }
    set_transport_checksum(&mut packet, &header);
    packet
}

/// Ответ UDP от `source` к `destination`. `None` — данные не влезают в
/// одну датаграмму или семейства адресов разные.
pub fn udp(source: SocketAddr, destination: SocketAddr, payload: &[u8]) -> Option<Vec<u8>> {
    if source.is_ipv4() != destination.is_ipv4() {
        return None;
    }
    let len = u16::try_from(UDP_HEADER + payload.len()).ok()?;
    let mut segment = Vec::with_capacity(usize::from(len));
    segment.extend_from_slice(&source.port().to_be_bytes());
    segment.extend_from_slice(&destination.port().to_be_bytes());
    segment.extend_from_slice(&len.to_be_bytes());
    segment.extend_from_slice(&[0, 0]);
    segment.extend_from_slice(payload);
    Some(build(source.ip(), destination.ip(), PROTO_UDP, &segment))
}

/// RST в ответ на сегмент, которому некуда идти (как `resetIPv4TCP` в
/// sing-tun). На RST не отвечаем.
pub fn tcp_reset(packet: &[u8], header: &Header) -> Option<Vec<u8>> {
    if header.protocol != PROTO_TCP || header.transport + TCP_HEADER > header.end {
        return None;
    }
    let t = &packet[header.transport..header.end];
    let flags = t[13];
    if flags & TCP_RST != 0 {
        return None;
    }
    let data_offset = usize::from(t[12] >> 4) * 4;
    let payload = t.len().saturating_sub(data_offset) as u32;
    let mut segment = [0u8; TCP_HEADER];
    segment[0..2].copy_from_slice(&t[2..4]);
    segment[2..4].copy_from_slice(&t[0..2]);
    segment[12] = (TCP_HEADER as u8 / 4) << 4;
    if flags & TCP_ACK != 0 {
        // Номер — тот, что подтвердил собеседник.
        segment[4..8].copy_from_slice(&t[8..12]);
        segment[13] = TCP_RST;
    } else {
        let mut ack = u32::from_be_bytes([t[4], t[5], t[6], t[7]]).wrapping_add(payload);
        if flags & TCP_SYN != 0 {
            ack = ack.wrapping_add(1);
        }
        if flags & TCP_FIN != 0 {
            ack = ack.wrapping_add(1);
        }
        segment[8..12].copy_from_slice(&ack.to_be_bytes());
        segment[13] = TCP_RST | TCP_ACK;
    }
    Some(build(
        header.destination,
        header.source,
        PROTO_TCP,
        &segment,
    ))
}

/// «Порт недоступен» в ответ на датаграмму UDP, которую туннель не
/// передаёт: QUIC в браузере сразу переходит на TCP, а не ждёт таймаута.
pub fn port_unreachable(packet: &[u8], header: &Header) -> Option<Vec<u8>> {
    if header.protocol != PROTO_UDP {
        return None;
    }
    let original = &packet[..header.end];
    let (protocol, kind, code, quoted) = if header.is_v4() {
        // Заголовок IP и первые 8 байт данных (RFC 792).
        let quoted = &original[..(header.transport + 8).min(original.len())];
        (PROTO_ICMP, 3u8, 3u8, quoted)
    } else {
        let room = IPV6_MIN_MTU - IPV6_HEADER - 8;
        (PROTO_ICMPV6, 1, 4, &original[..original.len().min(room)])
    };
    let mut message = Vec::with_capacity(8 + quoted.len());
    message.extend_from_slice(&[kind, code, 0, 0, 0, 0, 0, 0]);
    message.extend_from_slice(quoted);
    Some(build(header.destination, header.source, protocol, &message))
}

#[cfg(test)]
pub(crate) mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    /// Сегмент TCP от `source` к `destination` с данными.
    pub(crate) fn tcp_packet(
        source: SocketAddr,
        destination: SocketAddr,
        flags: u8,
        seq: u32,
        ack: u32,
        payload: &[u8],
    ) -> Vec<u8> {
        let mut segment = vec![0u8; TCP_HEADER];
        segment[0..2].copy_from_slice(&source.port().to_be_bytes());
        segment[2..4].copy_from_slice(&destination.port().to_be_bytes());
        segment[4..8].copy_from_slice(&seq.to_be_bytes());
        segment[8..12].copy_from_slice(&ack.to_be_bytes());
        segment[12] = 5 << 4;
        segment[13] = flags;
        segment[14..16].copy_from_slice(&65535u16.to_be_bytes());
        segment.extend_from_slice(payload);
        build(source.ip(), destination.ip(), PROTO_TCP, &segment)
    }

    /// Сумма верна, если пересчёт по пакету даёт ноль.
    pub(crate) fn checksums_valid(packet: &[u8]) -> bool {
        let header = parse(packet).unwrap();
        let ip_ok = !header.is_v4() || fold(sum(&packet[..header.transport], 0)) == 0;
        let segment = &packet[header.transport..header.end];
        let start = if header.protocol == PROTO_ICMP {
            0
        } else {
            pseudo_header(
                header.source,
                header.destination,
                header.protocol,
                segment.len(),
            )
        };
        ip_ok && fold(sum(segment, start)) == 0
    }

    fn addr(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    #[test]
    fn checksum_matches_rfc1071_example() {
        // Пример из RFC 1071, раздел 3.
        let data = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7];
        assert_eq!(fold(sum(&data, 0)), !0xddf2);
    }

    #[test]
    fn parses_and_rewrites_tcp_v4_and_v6() {
        for (from, to, new_from, new_to) in [
            (
                "10.0.0.5:51000",
                "93.184.216.34:443",
                "172.19.0.2:10000",
                "172.19.0.1:41000",
            ),
            (
                "[2001:db8::5]:51000",
                "[2606:4700::1]:443",
                "[fdfe:dcba:9876::2]:10000",
                "[fdfe:dcba:9876::1]:41000",
            ),
        ] {
            let mut packet = tcp_packet(addr(from), addr(to), TCP_SYN, 7, 0, b"hello");
            assert!(checksums_valid(&packet));
            let header = parse(&packet).unwrap();
            assert_eq!(header.protocol, PROTO_TCP);
            assert_eq!(header.source, addr(from).ip());
            assert_eq!(header.ports(&packet), Some((51000, 443)));
            assert!(rewrite_tcp(
                &mut packet,
                &header,
                addr(new_from),
                addr(new_to)
            ));
            let rewritten = parse(&packet).unwrap();
            assert_eq!(rewritten.source, addr(new_from).ip());
            assert_eq!(rewritten.destination, addr(new_to).ip());
            assert_eq!(rewritten.ports(&packet), Some((10000, 41000)));
            assert!(checksums_valid(&packet), "{from}");
            assert_eq!(&packet[rewritten.transport + 20..], b"hello");
            // Другое семейство адресов — отказ без порчи пакета.
            let other = if from.starts_with('[') {
                addr("1.1.1.1:1")
            } else {
                addr("[::1]:1")
            };
            let before = packet.clone();
            assert!(!rewrite_tcp(&mut packet, &rewritten, other, other));
            assert_eq!(packet, before);
        }
    }

    #[test]
    fn rejects_fragments_truncated_and_unknown() {
        let mut packet = tcp_packet(addr("10.0.0.1:1"), addr("10.0.0.2:2"), TCP_SYN, 0, 0, &[]);
        assert!(parse(&packet[..19]).is_none());
        assert!(parse(&[0x70; 40]).is_none());
        packet[6] |= 0x20; // MF
        assert!(parse(&packet).is_none());
        let mut v6 = tcp_packet(addr("[::2]:1"), addr("[::3]:2"), TCP_SYN, 0, 0, &[]);
        v6[5] += 1; // длина больше пакета
        assert!(parse(&v6).is_none());
    }

    #[test]
    fn reset_answers_syn_and_ack() {
        let syn = tcp_packet(
            addr("10.0.0.5:5000"),
            addr("1.2.3.4:80"),
            TCP_SYN,
            100,
            0,
            &[],
        );
        let reset = tcp_reset(&syn, &parse(&syn).unwrap()).unwrap();
        assert!(checksums_valid(&reset));
        let header = parse(&reset).unwrap();
        assert_eq!(header.source, addr("1.2.3.4:80").ip());
        assert_eq!(header.ports(&reset), Some((80, 5000)));
        let t = &reset[header.transport..];
        assert_eq!(t[13], TCP_RST | TCP_ACK);
        assert_eq!(u32::from_be_bytes([t[8], t[9], t[10], t[11]]), 101);

        let data = tcp_packet(
            addr("[::5]:5000"),
            addr("[::4]:80"),
            TCP_ACK,
            100,
            999,
            b"abc",
        );
        let reset = tcp_reset(&data, &parse(&data).unwrap()).unwrap();
        assert!(checksums_valid(&reset));
        let header = parse(&reset).unwrap();
        let t = &reset[header.transport..];
        assert_eq!(t[13], TCP_RST);
        assert_eq!(u32::from_be_bytes([t[4], t[5], t[6], t[7]]), 999);

        let rst = tcp_packet(addr("10.0.0.5:1"), addr("1.2.3.4:2"), TCP_RST, 0, 0, &[]);
        assert!(tcp_reset(&rst, &parse(&rst).unwrap()).is_none());
    }

    #[test]
    fn udp_reply_and_unreachable() {
        for (from, to) in [
            ("1.1.1.1:53", "10.0.0.5:6000"),
            ("[2606:4700::1111]:53", "[2001:db8::5]:6000"),
        ] {
            let reply = udp(addr(from), addr(to), b"answer").unwrap();
            assert!(checksums_valid(&reply));
            let header = parse(&reply).unwrap();
            assert_eq!(header.ports(&reply), Some((53, 6000)));
            assert_eq!(header.udp_payload(&reply), Some(&b"answer"[..]));

            let error = port_unreachable(&reply, &header).unwrap();
            assert!(checksums_valid(&error), "{from}");
            let icmp = parse(&error).unwrap();
            assert_eq!(icmp.destination, addr(from).ip());
            assert_eq!(icmp.source, addr(to).ip());
        }
        assert!(udp(addr("1.1.1.1:1"), addr("[::1]:1"), b"").is_none());
    }

    #[test]
    fn routable_addresses() {
        for ok in [
            "10.0.0.1",
            "172.19.0.1",
            "8.8.8.8",
            "2001:db8::1",
            "fdfe::1",
        ] {
            assert!(is_routable(ok.parse().unwrap()), "{ok}");
        }
        for no in [
            "0.0.0.0",
            "127.0.0.1",
            "224.0.0.251",
            "169.254.1.1",
            "255.255.255.255",
            "::",
            "::1",
            "ff02::fb",
            "fe80::1",
        ] {
            assert!(!is_routable(no.parse().unwrap()), "{no}");
        }
    }
}
