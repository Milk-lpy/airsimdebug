package com.airsim.phonecontrol;

import java.net.URI;

final class HomeRelayRoute {
    private static final String HOST = RelayProfile.LAN;
    private static final int PORT = 18787;
    private static final String TUNNEL_HOST = RelayProfile.TUNNEL;
    private static final int TLS_PORT = 18788;

    private static boolean privateRelayOrigin(URI value) {
        String path = value.getRawPath();
        if (!valid(value) || value.getRawQuery() != null
                || !(path.isEmpty() || path.equals("/"))) return false;
        if (!(HOST.equals(value.getHost()) || TUNNEL_HOST.equals(value.getHost()))) return false;
        return value.getPort() == PORT && "http".equalsIgnoreCase(value.getScheme())
                || value.getPort() == TLS_PORT && "https".equalsIgnoreCase(value.getScheme());
    }

    // Both addresses belong to the same private Relay. Keep the original
    // pairing scope for the SMS queues and their encryption key on refresh.
    static boolean samePrivateRelay(String saved, String refreshed) {
        try {
            return privateRelayOrigin(URI.create(saved)) && privateRelayOrigin(URI.create(refreshed));
        } catch (IllegalArgumentException invalidOrigin) {
            return false;
        }
    }

    private static boolean valid(URI value) {
        return value.getHost() != null && value.getRawUserInfo() == null
                && value.getRawFragment() == null
                && (value.getPort() == -1 || value.getPort() > 0 && value.getPort() <= 65535);
    }

    private static boolean home(URI value) {
        return HOST.equals(value.getHost()) && value.getPort() == PORT;
    }

    static boolean allowsBase(URI value) {
        return valid(value) && value.getRawQuery() == null
                && ("https".equalsIgnoreCase(value.getScheme())
                || "http".equalsIgnoreCase(value.getScheme()) && (home(value) || privateRelayOrigin(value)));
    }

    /** A bare tunnel IP uses the standalone installer's port. Explicit URLs retain their ports. */
    static String normalizeManualAddress(String input) {
        String text = input == null ? "" : input.trim();
        if (text.isEmpty() || text.length() > 2048) throw new IllegalArgumentException("请输入有效的 Relay 地址");
        try {
            boolean explicit = text.contains("://");
            if (!explicit && text.indexOf(':') != text.lastIndexOf(':') && !text.startsWith("[") && !text.contains("/")) {
                text = "[" + text + "]";
            }
            URI uri = URI.create(explicit ? text : "https://" + text);
            if (!allowsBase(uri) || uri.getRawAuthority().endsWith(":") || !uri.normalize().equals(uri)
                    || !("https".equalsIgnoreCase(uri.getScheme()) || privateRelayOrigin(uri))) {
                throw new IllegalArgumentException();
            }
            String host = uri.getHost();
            if (host.matches("[0-9.]+")) {
                String[] octets = host.split("\\.", -1);
                if (octets.length != 4) throw new IllegalArgumentException();
                for (String part : octets) if (!part.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(part) > 255)
                    throw new IllegalArgumentException();
            }
            if (!explicit && uri.getPort() == -1 && (host.startsWith("[") || host.matches("[0-9.]+"))) {
                uri = URI.create("https://" + host + ":" + TLS_PORT + uri.getRawPath());
            }
            return endpointBase(uri);
        } catch (IllegalArgumentException invalid) {
            throw new IllegalArgumentException("请输入有效的 HTTPS 地址，例如 https://10.8.0.2:18788；请去掉账户、查询参数和片段");
        }
    }

    static boolean allowsSocket(URI value) {
        return valid(value) && ("wss".equalsIgnoreCase(value.getScheme())
                || "ws".equalsIgnoreCase(value.getScheme()) && home(value));
    }

    static boolean isHomeHTTP(URI value) {
        return allowsBase(value) && "http".equalsIgnoreCase(value.getScheme());
    }

    static String endpointBase(URI value) {
        if (!allowsBase(value)) throw new IllegalArgumentException("不支持的 Relay 地址");
        if (privateRelayOrigin(value)) return "https://" + value.getHost() + ":" + TLS_PORT;
        return value.toString().replaceFirst("/+$", "");
    }

    static String websocketBase(URI value) {
        String base = endpointBase(value);
        return ("https".equalsIgnoreCase(URI.create(base).getScheme()) ? "wss" : "ws") + base.substring(base.indexOf(':'));
    }
}
