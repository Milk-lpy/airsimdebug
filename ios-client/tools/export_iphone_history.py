#!/usr/bin/env python3
"""Convert selected, already-decrypted iPhone SQLite snapshots to an AirSIM history JSON."""
import argparse
import base64
import errno
from collections import Counter, defaultdict
from contextlib import closing, contextmanager, ExitStack
from datetime import date as calendar_date, datetime, time, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import tempfile
import uuid

APPLE_EPOCH = 978307200
FORMAT = "airsim-iphone-history"
FILE_LIMIT = 32 * 1024 * 1024
PACK_LIMIT = 128 * 1024 * 1024
PACK_LIMIT_MESSAGE = "迁移包超过 128 MB。请用 --from-date 和 --before-date 分段导出。"


def identifier(*parts):
    encoded = json.dumps(parts, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def optional_text(value):
    if isinstance(value, bytes):
        try:
            value = value.decode("utf-8")
        except UnicodeDecodeError:
            return None
    if isinstance(value, str):
        return value.strip() or None
    return None


def flag(value):
    if value in (0, "0"):
        return False
    if value in (1, "1"):
        return True
    return None


def finite_number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError, OverflowError):
        return None


def timestamp(value):
    date = finite_number(value)
    if date is None or date <= 0:
        return None
    # Older sms.db and Core Data use seconds. Modern sms.db uses nanoseconds.
    if date >= 1e15:
        date /= 1e9
    if date > 1e10:
        return None
    return date + APPLE_EPOCH


def uuid_string(value):
    if not value:
        return None
    try:
        if isinstance(value, bytes) and len(value) == 16:
            result = uuid.UUID(bytes=value)
        else:
            result = uuid.UUID(optional_text(value) or "")
        return str(result) if result.int != 0 else None
    except ValueError:
        return None


@contextmanager
def snapshot(source, wal):
    # SQLite may discover sidecars even on a read-only connection. Isolate the
    # selected files and let SQLite create its transient shared-memory file here.
    with tempfile.TemporaryDirectory(prefix="airsim-history-") as temp_dir:
        copy = Path(temp_dir, "snapshot.sqlite")
        if not source.is_file():
            raise ValueError("所选数据库不是普通文件")
        shutil.copyfile(source, copy)
        if wal:
            if not wal.is_file():
                raise ValueError("所选 WAL 不是普通文件")
            with wal.open("rb") as stream:
                header = stream.read(32)
            if len(header) != 32 or header[:4] not in (b"\x37\x7f\x06\x82", b"\x37\x7f\x06\x83"):
                raise ValueError("所选 WAL 文件头无效")
            shutil.copyfile(wal, str(copy) + "-wal")
        with closing(sqlite3.connect(copy.as_uri() + "?mode=ro", uri=True)) as db:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA trusted_schema=OFF")
            db.execute("PRAGMA query_only=ON")
            yield db


def columns(db, table):
    # Every table and column name used to compose SQL is a code constant.
    if not db.execute("SELECT 1 FROM sqlite_master WHERE lower(name)=lower(?) AND type='table' AND rootpage>0",
                      (table,)).fetchone():
        return set()
    return {row["name"].lower() for row in db.execute(f'PRAGMA table_info("{table}")')}


def fields(names, present, prefix):
    return ", ".join(f'{prefix}."{name}" AS "{name}"' if name.lower() in present else f'NULL AS "{name}"'
                     for name in names.split())


def attachment_parts(value):
    raw = value if isinstance(value, str) else None
    if not raw or "\x00" in raw or "\\" in raw:
        return ()
    prefixes = ("~/Library/SMS/Attachments/", "/private/var/mobile/Library/SMS/Attachments/",
                "/var/mobile/Library/SMS/Attachments/", "MediaDomain/Library/SMS/Attachments/",
                "Library/SMS/Attachments/", "Attachments/")
    for prefix in prefixes:
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
            break
    parts = raw.split("/")
    windows_devices = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
    windows_devices.update(prefix + digit for prefix in ("COM", "LPT") for digit in "0123456789¹²³")
    if any(part in ("", ".", "..") or ":" in part or part.startswith("~")
           or part.endswith((" ", ".")) or part.partition(".")[0].rstrip().upper() in windows_devices for part in parts):
        return ()
    return tuple(parts)


class UnsafeAttachment(Exception):
    pass


def windows_final_path(stream):
    """Resolve the file actually opened, including any Windows junctions."""
    import ctypes
    import msvcrt
    from ctypes import wintypes
    final_path = ctypes.WinDLL("kernel32", use_last_error=True).GetFinalPathNameByHandleW
    final_path.argtypes = (wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD)
    final_path.restype = wintypes.DWORD
    handle = msvcrt.get_osfhandle(stream.fileno())
    size = final_path(handle, None, 0, 0)
    if not size:
        raise UnsafeAttachment()
    buffer = ctypes.create_unicode_buffer(size + 1)
    length = final_path(handle, buffer, len(buffer), 0)
    if not length or length >= len(buffer):
        raise UnsafeAttachment()
    value = buffer.value
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return Path(value)


@contextmanager
def open_attachment(root, root_fd, parts):
    if root_fd is None:  # Windows verifies the final handle path before reading.
        path = root.joinpath(*parts)
        if not path.resolve(strict=True).is_relative_to(root):
            raise UnsafeAttachment()
        with path.open("rb") as stream:
            if not windows_final_path(stream).is_relative_to(root):
                raise UnsafeAttachment()
            yield stream
        return
    with ExitStack() as stack:
        current = root_fd
        for part in parts[:-1]:
            current = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            stack.callback(os.close, current)
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=current)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise UnsafeAttachment()
            yield stream


class AttachmentReader:
    def __init__(self, db, root, root_fd, stats):
        self.db = db
        self.root = root
        self.root_fd = root_fd
        self.stats = stats
        meta = columns(db, "attachment")
        self.query = None
        if "filename" in meta and {"message_id", "attachment_id"} <= columns(db, "message_attachment_join"):
            metadata = fields("filename mime_type transfer_name", meta, "a")
            self.query = (f"SELECT DISTINCT j.attachment_id AS aid,{metadata} FROM message_attachment_join j "
                          "LEFT JOIN attachment a ON a.rowid=j.attachment_id WHERE j.message_id=? ORDER BY aid")

    def read(self, row_id, remaining):
        files = []
        refs = self.db.execute(self.query, (row_id,)) if self.query else ()
        referenced = False
        for row in refs:
            referenced = True
            parts = attachment_parts(row["filename"])
            if not parts:
                self.stats["unavailable_attachments"] += 1
                continue
            try:
                with open_attachment(self.root, self.root_fd, parts) as stream:
                    size = os.fstat(stream.fileno()).st_size
                    if size > FILE_LIMIT:
                        raise ValueError("选定范围内的单个附件超过 32 MB。可单独保留该原始媒体，按日期缩小范围或省略 --attachments-dir 导出文字。")
                    if ((size + 2) // 3) * 4 > remaining:
                        raise ValueError(PACK_LIMIT_MESSAGE)
                    data = stream.read(FILE_LIMIT + 1)
                    if len(data) != size:
                        raise ValueError("附件大小在读取期间发生变化，请重新复制静止的快照后再导出。")
            except (UnsafeAttachment, OSError):
                self.stats["unavailable_attachments"] += 1
                continue
            file_name = optional_text(row["transfer_name"]) or parts[-1]
            # Metadata is display-only. Never carry a file path into the package.
            file_name = file_name.replace("\\", "/").split("/")[-1]
            if not file_name or file_name in (".", "..") or any(ord(c) < 32 for c in file_name):
                file_name = parts[-1]
            mime = optional_text(row["mime_type"]) or "application/octet-stream"
            if "/" not in mime or mime.lower().startswith("application/vnd.airsim.") or any(ord(c) < 32 for c in mime):
                mime = "application/octet-stream"
            encoded = base64.b64encode(data).decode("ascii")
            files.append({"name": file_name, "mimeType": mime, "data": encoded})
            remaining -= len(encoded)
            self.stats["attachments"] += 1
        if not referenced:
            self.stats["unavailable_attachments"] += 1
        return files


def body_text(blob):
    if not isinstance(blob, bytes) or not blob.startswith(b"\x04\x0bstreamtyped"):
        return None
    # The body is the inline UTF-8 NSString in the NSAttributedString object.
    # Never search arbitrary printable bytes, which could be an attribute name.
    marker = blob.find(b"NSString")
    if marker < 0:
        return None
    tag = blob.find(b"\x01+", marker + 8, marker + 24)
    if tag < 0 or tag + 2 >= len(blob):
        return None
    position = tag + 3
    length = blob[position - 1]
    if length in (0x81, 0x82):
        width = 2 if length == 0x81 else 4
        if position + width > len(blob):
            return None
        length = int.from_bytes(blob[position:position + width], "little")
        position += width
    elif length >= 0x80:
        return None
    end = position + length
    if blob[end:end + 1] != b"\x86":
        return None
    try:
        return blob[position:end].decode("utf-8")
    except UnicodeDecodeError:
        return None


def sms_rows(db, source_id, stats):
    message = columns(db, "message")
    if not {"date", "is_from_me"} <= message:
        raise ValueError("短信数据库缺少 message/date/is_from_me")
    handles = {}
    if "id" in columns(db, "handle"):
        handles = dict(db.execute("SELECT rowid, id FROM handle"))
    chats = {}
    chat = columns(db, "chat")
    if chat:
        chats = {row["rid"]: row for row in db.execute(
            'SELECT rowid AS rid, ' + fields("guid chat_identifier display_name style service_name", chat, "c") + " FROM chat c")}
    members = defaultdict(set)
    if {"chat_id", "handle_id"} <= columns(db, "chat_handle_join"):
        for chat_id, handle_id in db.execute("SELECT chat_id,handle_id FROM chat_handle_join"):
            address = optional_text(handles.get(handle_id))
            if address:
                members[chat_id].add(address)

    joins = {"chat_id", "message_id"} <= columns(db, "chat_message_join") and bool(chat)
    attachment_join = "message_id" in columns(db, "message_attachment_join")
    row_fields = fields("guid date is_from_me handle_id text attributedBody service destination_caller_id is_mms "
                        "cache_has_attachments", message, "m")
    chat_id_expr = "link.chat_id" if joins else "NULL"
    attachment_expr = ("EXISTS(SELECT 1 FROM message_attachment_join att WHERE att.message_id=m.rowid)"
                       if attachment_join else "0")
    query = f"SELECT m.rowid AS rid, {row_fields}, {chat_id_expr} AS chat_id, {attachment_expr} AS attached FROM message m"
    if joins:
        query += " LEFT JOIN chat_message_join link ON link.message_id=m.rowid"
    for row in db.execute(query):
        outgoing, when = flag(row["is_from_me"]), timestamp(row["date"])
        if outgoing is None or when is None:
            stats["skipped_messages"] += 1
            continue
        chat_id = row["chat_id"]
        info = chats.get(chat_id)
        known = members.get(chat_id, set())
        address = optional_text(handles.get(row["handle_id"]))
        chat_key = optional_text(info["chat_identifier"]) if info else None
        chat_guid = optional_text(info["guid"]) if info else None
        group = (len(known) > 1 or bool(info and info["style"] == 43)
                 or bool(chat_guid and ";+;" in chat_guid)
                 or bool(chat_key and chat_key.startswith("chat") and chat_key[4:].isdigit()))
        peer = None if group else next(iter(known), None) or chat_key or address
        line = optional_text(row["destination_caller_id"])
        service = optional_text(row["service"]) or (optional_text(info["service_name"]) if info else None)
        service = {"imessage": "iMessage", "sms": "SMS", "mms": "MMS", "rcs": "RCS"}.get((service or "").lower(), "unknown")
        if flag(row["is_mms"]) and service in ("SMS", "unknown"):
            service = "MMS"
        guid = optional_text(row["guid"])
        if info:
            chat_key = chat_guid or chat_key or peer or ("chat", chat_id)
        else:
            chat_key = peer
        thread = identifier("thread", source_id, line, service, chat_key or ("unresolved", guid or row["rid"]))
        record_id = identifier("message", thread, guid or (row["rid"], when, outgoing))
        title = (optional_text(info["display_name"]) if info else None) or peer
        if not title:
            title = "、".join(sorted(known)) or ("群聊" if group else "未知联系人")
        content = row["text"] if isinstance(row["text"], str) else None
        content = (content or body_text(row["attributedBody"]) or "").replace("\ufffc", "[附件]")
        attached = row["attached"] or flag(row["cache_has_attachments"])
        if attached and "[附件]" not in content:
            content = (content + "\n" if content else "") + "[附件]"
        if not content:
            content = "[未能解析的消息内容]" if row["attributedBody"] else "[无文本记录]"
        record = {"id": record_id, "threadID": thread, "title": title, "direction": "outgoing" if outgoing else "incoming",
                  "timestamp": when, "service": service, "text": content, "readOnly": True}
        for key, value in (("peer", peer), ("sender", line if outgoing else address), ("line", line)):
            if value:
                record[key] = value
        yield record, row["rid"] if attached else None


def call_rows(db, source_id, stats):
    call = columns(db, "ZCALLRECORD")
    if not {"zdate", "zoriginated"} <= call:
        raise ValueError("通话数据库缺少 ZCALLRECORD/ZDATE/ZORIGINATED")
    names = ("ZDATE ZORIGINATED ZADDRESS ZDURATION ZANSWERED ZCALLTYPE ZSERVICE_PROVIDER "
             "ZUNIQUE_ID ZLOCALPARTICIPANTUUID")
    for row in db.execute("SELECT rowid AS rid, " + fields(names, call, "c") + " FROM ZCALLRECORD c"):
        outgoing, when = flag(row["ZORIGINATED"]), timestamp(row["ZDATE"])
        if outgoing is None or when is None:
            stats["skipped_calls"] += 1
            continue
        system_id = uuid_string(row["ZUNIQUE_ID"])
        number = optional_text(row["ZADDRESS"])
        provider = optional_text(row["ZSERVICE_PROVIDER"])
        kind = row["ZCALLTYPE"]
        provider_key = (provider or "").lower()
        if provider_key == "com.apple.telephony" or (not provider and kind == 1):
            service = "cellular"
        elif provider_key == "com.apple.facetime" or (not provider and kind in (8, 16)):
            service = "FaceTime"
        else:
            service = provider or "unknown"
        duration = finite_number(row["ZDURATION"])
        answered = flag(row["ZANSWERED"])
        line = uuid_string(row["ZLOCALPARTICIPANTUUID"])
        record_id = identifier("call", system_id) if system_id else identifier(
            "call", source_id, row["rid"], when, number, line, service, outgoing)
        record = {"id": record_id, "timestamp": when, "service": service, "direction": "outgoing" if outgoing else "incoming"}
        for key, value in (("number", number), ("systemID", system_id), ("line", line), ("answered", answered),
                           ("duration", duration if duration is not None and duration >= 0 else None)):
            if value is not None:
                record[key] = value
        yield record, None


def write_rows(stream, source, wal, export, source_id, stats, start, end, attachment_dir=None):
    stream.write("[")
    seen = set()
    if source:
        with snapshot(source, wal) as db, ExitStack() as resources:
            reader = None
            if attachment_dir is not None:
                root = attachment_dir.resolve(strict=True)
                if not root.is_dir():
                    raise ValueError("--attachments-dir 必须指向已导出的附件目录")
                root_fd = None
                if os.name != "nt":
                    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                    resources.callback(os.close, root_fd)
                reader = AttachmentReader(db, root, root_fd, stats)
            for record, attachment_row in export(db, source_id, stats):
                if (start is not None and record["timestamp"] < start) or (end is not None and record["timestamp"] >= end):
                    continue
                if record["id"] in seen:
                    continue
                if reader and attachment_row is not None:
                    files = reader.read(attachment_row, PACK_LIMIT - stream.tell())
                    if files:
                        record["attachments"] = files
                if record.get("text") in ("[未能解析的消息内容]", "[无文本记录]"):
                    stats["placeholder_messages"] += 1
                if seen:
                    stream.write(",")
                json.dump(record, stream, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
                if stream.tell() > PACK_LIMIT:
                    raise ValueError(PACK_LIMIT_MESSAGE)
                seen.add(record["id"])
    stream.write("]")
    return len(seen)


def run(args):
    if not (args.sms_db or args.calls_db):
        raise ValueError("请指定 --sms-db 或 --calls-db")
    if args.attachments_dir and not args.sms_db:
        raise ValueError("--attachments-dir 需要与 --sms-db 一起使用")
    if (args.sms_wal and not args.sms_db) or (args.calls_wal and not args.calls_db):
        raise ValueError("WAL 文件需要与对应数据库一起选择")
    def midnight(day):
        return datetime.combine(day, time(), tzinfo=timezone.utc).timestamp() if day else None

    start = midnight(args.from_date)
    end = midnight(args.before_date)
    if start is not None and end is not None and start >= end:
        raise ValueError("--from-date 必须早于 --before-date")
    stats = Counter()
    # Create the final file only after both conversions finish. Hard-linking
    # from the same directory atomically publishes without replacing an existing file.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.output.parent,
                                     prefix=".airsim-history-", delete=False) as out:
        temporary = Path(out.name)
        try:
            out.write('{"format":"' + FORMAT + '","version":1,"messages":')
            stats["messages"] = write_rows(out, args.sms_db, args.sms_wal, sms_rows, args.source_id, stats, start, end, args.attachments_dir)
            out.write(',"calls":')
            stats["calls"] = write_rows(out, args.calls_db, args.calls_wal, call_rows, args.source_id, stats, start, end)
            out.write("}\n")
            out.close()
            if temporary.stat().st_size > PACK_LIMIT:
                raise ValueError(PACK_LIMIT_MESSAGE)
            try:
                os.link(temporary, args.output)
            except OSError as error:
                # Removable FAT/exFAT volumes commonly lack hard links. Create
                # the destination exclusively and remove a partial copy on failure.
                if error.errno not in (errno.EPERM, errno.ENOTSUP, errno.ENOSYS):
                    raise
                fd = os.open(args.output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                try:
                    with os.fdopen(fd, "wb") as target, temporary.open("rb") as source:
                        shutil.copyfileobj(source, target)
                except BaseException:
                    args.output.unlink()
                    raise
        finally:
            out.close()
            temporary.unlink(missing_ok=True)
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sms-db", type=Path, help="已导出的 sms.db")
    parser.add_argument("--sms-wal", type=Path, help="同一快照的 sms.db-wal（可选）")
    parser.add_argument("--attachments-dir", type=Path, help="用户选定的消息附件根目录（可选），保留原始子目录结构")
    parser.add_argument("--calls-db", type=Path, help="已导出的 CallHistory.storedata")
    parser.add_argument("--calls-wal", type=Path, help="同一快照的 CallHistory.storedata-wal（可选）")
    parser.add_argument("--from-date", type=calendar_date.fromisoformat, help="UTC 起始日期（含），例如 2024-01-01")
    parser.add_argument("--before-date", type=calendar_date.fromisoformat, help="UTC 截止日期（不含），例如 2025-01-01")
    parser.add_argument("--source-id", default="iphone", help="同一部手机每次导出使用相同名称")
    parser.add_argument("--output", type=Path, required=True, help="新的 JSON 输出文件")
    args = parser.parse_args()
    try:
        stats = run(args)
    except (OSError, sqlite3.Error, ValueError) as error:
        parser.exit(1, f"导出失败：{error}\n")
    if args.attachments_dir:
        print(f"已带入 {stats['attachments']} 个附件。缺失、无效路径或无法安全读取的附件共 {stats['unavailable_attachments']} 个，保留占位。")
    print(f"已导出短信 {stats['messages']} 条、通话 {stats['calls']} 条。无法解析正文的占位记录 {stats['placeholder_messages']} 条。"
          f"无有效时间或方向而跳过的短信 {stats['skipped_messages']} 条、通话 {stats['skipped_calls']} 条。")


if __name__ == "__main__":
    main()
