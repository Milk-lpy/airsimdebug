package com.airsim.phonecontrol;

import org.json.JSONArray;
import org.json.JSONObject;
import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;

/** Explicit reject rules only: do not assume Android has the iPhone's contacts. */
final class SMSNotificationFilter {
    private static final Pattern OTP = Pattern.compile("(?<![0-9])[0-9]{4,8}(?![0-9])");
    private static final String[] OTP_WORDS = {"验证码","驗證碼","动态密码","動態密碼","校验码",
        "verification code","one-time password","otp"};
    private SMSNotificationFilter() {}

    static boolean suppress(JSONObject registration, JSONObject sms) {
        JSONObject config = registration.optJSONObject("sms_alert_filter_v1");
        if (config == null) return false;
        JSONArray allow = config.optJSONArray("allow");
        JSONArray rules = config.optJSONArray("rules");
        if (allow == null || rules == null || allow.length() > 250 || rules.length() > 250) return false;
        String sender = sender(sms.optString("sender", ""));
        String raw = sms.optString("content", "");
        if (sender.isEmpty() || raw.isEmpty() || raw.length() > 8192) return false;
        if (!sms.optString("code", "").trim().isEmpty()) return false;
        String body = normalize(raw);
        if (OTP.matcher(body).find()) {
            for (String word : OTP_WORDS) if (body.contains(word)) return false;
        }
        for (int i = 0; i < allow.length(); i++) {
            Object term = allow.opt(i);
            if (!(term instanceof String) || ((String)term).length() > 256) return false;
            if (sender.equals(sender((String)term))) return false;
        }
        boolean rejected = false;
        for (int i = 0; i < rules.length(); i++) {
            JSONObject rule = rules.optJSONObject(i);
            if (rule == null) return false;
            Object term = rule.opt("keyword");
            if (!(term instanceof String) || ((String)term).length() > 256) return false;
            String kw = normalize((String)term);
            String target = rule.optString("target", "");
            if (!target.equals("sender") && !target.equals("content")) return false;
            if (!kw.isEmpty()) rejected |= target.equals("sender") ? sender.equals(sender(kw)) : body.contains(kw);
        }
        return rejected;
    }

    private static String normalize(String value) {
        return Normalizer.normalize(value, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT).strip();
    }
    private static String sender(String raw) {
        String value = normalize(raw), compact = value.replaceAll("[ ().-]", "");
        if (!compact.matches("[0-9+]+")) return value;
        return compact.startsWith("+86") && compact.length() == 14 ? compact.substring(3) : compact;
    }
}
