import argparse
import base64
from datetime import date
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from export_iphone_history import APPLE_EPOCH, body_text, run


class ExportTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.sms = self.root / "sms.db"
        self.calls = self.root / "CallHistory.storedata"

    def options(self, output="history.json", **extra):
        return argparse.Namespace(**dict(dict(output=self.root / output, source_id="one", attachments_dir=None, from_date=None, before_date=None,
                                              calls_db=None, sms_db=None, sms_wal=None, calls_wal=None), **extra))

    def make_sms(self, db):
        db.executescript("""
            CREATE TABLE message(date INTEGER, is_from_me INT, guid TEXT, handle_id INT, destination_caller_id TEXT,
                                 text TEXT, service TEXT, attributedBody BLOB);
            CREATE TABLE handle(id TEXT);
            CREATE TABLE chat(guid TEXT, chat_identifier TEXT, display_name TEXT, style INT);
            CREATE TABLE chat_handle_join(chat_id INT, handle_id INT);
            CREATE TABLE chat_message_join(chat_id INT, message_id INT);
            CREATE TABLE message_attachment_join(message_id INT, attachment_id INT);
            INSERT INTO handle VALUES('+100000001'),('+4400000001');
            INSERT INTO chat VALUES('SMS;-;+100000001','+100000001',NULL,45),('iMessage;+;chat123','chat123','家人',43);
            INSERT INTO chat_handle_join VALUES(1,1),(2,1),(2,2);
            INSERT INTO message VALUES(800000000,1,'one',0,'+10000','hello','SMS',NULL),
             (800000001000000000,0,'two',1,'+10001','另一张卡','SMS',NULL),
             (800000002000000000,0,'three',2,'+10000',NULL,'iMessage',NULL),
             (800000003,0,'four',1,'+10000',NULL,'SMS',X'00'),(NULL,NULL,'bad',0,NULL,'?','SMS',NULL);
            INSERT INTO chat_message_join VALUES(1,1),(1,1),(1,2),(2,3),(1,4);
            INSERT INTO message_attachment_join VALUES(3,1);
        """)

    def test_direct_group_lines_timestamps_and_stable_identifiers(self):
        with sqlite3.connect(self.sms) as db:
            self.make_sms(db)
        with sqlite3.connect(self.calls) as db:
            db.executescript("""
                CREATE TABLE ZCALLRECORD(ZDATE REAL,ZORIGINATED INTEGER,ZANSWERED INTEGER,ZDURATION REAL,
                    ZUNIQUE_ID TEXT,ZADDRESS TEXT, ZCALLTYPE INTEGER, ZLOCALPARTICIPANTUUID BLOB);
                INSERT INTO ZCALLRECORD VALUES(800000000.5,0,0,0,'425F1CE4-C612-411A-BBAA-155E4AC90E20','+10001',1,NULL),
                    (800000001,1,NULL,NULL,'not-a-uuid','person@example.org',8,NULL);
            """)
        before = [hashlib.sha256(f.read_bytes()).digest() for f in (self.sms, self.calls)]
        opt = self.options(sms_db=self.sms, calls_db=self.calls)
        stats = run(opt)
        export = json.loads(opt.output.read_text())
        self.assertEqual((stats["messages"], stats["calls"], stats["skipped_messages"]), (4,2,1))
        self.assertEqual(export["format"], "airsim-iphone-history")
        one, two, group, undecoded = sorted(export["messages"], key=lambda x:x["timestamp"])
        self.assertEqual((one["peer"], one["direction"]), ("+100000001", "outgoing"))
        self.assertEqual(two["timestamp"], APPLE_EPOCH + 800000001)
        self.assertNotEqual(one["threadID"], two["threadID"])
        self.assertEqual((group["service"], group["text"], group["title"], group["sender"]),
                         ("iMessage", "[附件]", "家人", "+4400000001"))
        self.assertTrue(group["readOnly"])
        self.assertNotIn("peer", group)
        self.assertEqual(undecoded["text"], "[未能解析的消息内容]")
        missed, facetime = export["calls"]
        self.assertIs(missed["answered"], False)
        self.assertEqual(missed["systemID"], "425f1ce4-c612-411a-bbaa-155e4ac90e20")
        self.assertEqual(missed["timestamp"], APPLE_EPOCH + 800000000.5)
        self.assertEqual(facetime["service"], "FaceTime")
        self.assertNotIn("systemID", facetime)
        self.assertNotIn("answered", facetime)
        self.assertNotIn("duration", facetime)
        self.assertEqual(before, [hashlib.sha256(f.read_bytes()).digest() for f in (self.sms,self.calls)])
        other = self.options("repeated.json", sms_db=self.sms, calls_db=self.calls)
        run(other)
        self.assertEqual(json.loads(other.output.read_text()), export)
        empty_window = self.options("window.json", sms_db=self.sms, calls_db=self.calls, before_date=date(2005,1,1))
        self.assertEqual(run(empty_window)["messages"], 0)
        with self.assertRaises(FileExistsError):
            run(opt)

    def test_only_explicitly_selected_wal_is_used(self):
        db = sqlite3.connect(self.sms)
        self.addCleanup(db.close)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA wal_autocheckpoint=0")
        self.make_sms(db)
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.execute("INSERT INTO message(date,is_from_me,handle_id,text,service) VALUES(800000004,0,1,'WAL','SMS')")
        db.commit()
        wal = self.root/"sms.db-wal"
        opts = self.options(sms_db=self.sms)
        self.assertEqual(run(opts)["messages"], 4)
        chosen = self.options("with-wal.json", sms_db=self.sms, sms_wal=wal)
        self.assertEqual(run(chosen)["messages"], 5)

    def test_text_body_validates_utf8_and_length_and_bounds(self):
        for text in ("好", "长"*220):
            raw = text.encode()
            size = bytes([len(raw)]) if len(raw) < 128 else b"\x81" + len(raw).to_bytes(2,"little")
            blob = b"\x04\x0bstreamtyped" + b"NSString\x01\x94\x84\x01+"+size+raw+b"\x86\x84"
            self.assertEqual(body_text(blob), text)
            self.assertIsNone(body_text(blob[:-6]))
        self.assertIsNone(body_text(b"unrelated \x01+\x03abc\x86"))

    def test_only_linked_attachments_inside_chosen_directory_are_embedded(self):
        folder = self.root / "Attachments"
        (folder / "aa").mkdir(parents=True)
        (folder / "aa" / "cat.jpg").write_bytes(b"expected photo")
        (folder / "unused.dat").write_bytes(b"unrelated")
        outside = self.root / "not-selected.dat"
        outside.write_bytes(b"private file")
        files = [("~/Library/SMS/Attachments/aa/cat.jpg", "image/jpeg", "../photo.jpg"),
                 ("~/Library/SMS/Attachments/../not-selected.dat", None, None),
                 (str(outside), None, None), ("aa/missing.gif", None, None),
                 ("C:\\Private\\x", None, None)]
        try:
            (folder / "aa" / "symlink").symlink_to(outside)
            (folder / "alias").symlink_to(self.root, target_is_directory=True)
        except OSError:
            pass  # Windows may disallow test-created symlinks.
        else:
            files += [("aa/symlink", None, None), ("alias/not-selected.dat", None, None)]
        with sqlite3.connect(self.sms) as db:
            self.make_sms(db)
            db.execute("CREATE TABLE attachment(filename TEXT, mime_type TEXT, transfer_name TEXT)")
            db.executemany("INSERT INTO attachment VALUES(?,?,?)", files)
            # Synthetic chat already has an attachment link for ID 1. Include it
            # again to check duplicate joins, and put all bad links on this message.
            db.executemany("INSERT INTO message_attachment_join VALUES(3,?)", [(i,) for i in range(1,len(files)+1)])
            db.execute("INSERT INTO chat_message_join VALUES(2,3)")
        plain = self.options(sms_db=self.sms)
        run(plain)
        opts = self.options("images.json", sms_db=self.sms, attachments_dir=folder)
        stats = run(opts)
        records = json.loads(opts.output.read_text())["messages"]
        previous = json.loads(plain.output.read_text())["messages"]
        self.assertEqual([r["id"] for r in records], [r["id"] for r in previous])
        message = next(row for row in records if row["service"] == "iMessage")
        self.assertEqual(message["attachments"], [{"name": "photo.jpg", "mimeType": "image/jpeg",
                                                     "data": base64.b64encode(b"expected photo").decode()}])
        self.assertEqual(message["text"], "[附件]")
        self.assertEqual(stats["attachments"], 1)
        self.assertEqual(stats["unavailable_attachments"], len(files)-1)
        self.assertNotIn(base64.b64encode(b"private file").decode(), opts.output.read_text())
        self.assertNotIn(base64.b64encode(b"unrelated").decode(), opts.output.read_text())

    def test_oversized_file_or_package_fails_without_discarding_the_record(self):
        folder = self.root / "files"
        folder.mkdir()
        (folder / "voice.amr").write_bytes(b"voice recording")
        with sqlite3.connect(self.sms) as db:
            self.make_sms(db)
            db.execute("CREATE TABLE attachment(filename TEXT)")
            db.execute("INSERT INTO attachment VALUES('voice.amr')")
        opts = self.options(sms_db=self.sms, attachments_dir=folder)
        with patch("export_iphone_history.FILE_LIMIT", 4), self.assertRaisesRegex(ValueError, "32 MB"):
            run(opts)
        self.assertFalse(opts.output.exists())
        with patch("export_iphone_history.PACK_LIMIT", 32), self.assertRaisesRegex(ValueError, "128 MB"):
            run(opts)
        self.assertFalse(opts.output.exists())
        opts.before_date = date(2005,1,1)
        with patch("export_iphone_history.FILE_LIMIT", 4):
            self.assertEqual(run(opts)["attachments"], 0)

    def test_invalid_db_preserves_existing_output_and_creates_no_partial_file(self):
        self.sms.write_bytes(b"not sqlite")
        options = self.options(sms_db=self.sms)
        with self.assertRaises(sqlite3.DatabaseError):
            run(options)
        self.assertFalse(options.output.exists())
        self.assertEqual(list(self.root.glob(".airsim-history-*")), [])


if __name__ == "__main__":
    unittest.main()
