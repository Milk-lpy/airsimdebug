import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from export_iphone_history import APPLE_EPOCH, body_text, run


class ExportTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.sms = self.root / "sms.db"
        self.calls = self.root / "CallHistory.storedata"

    def options(self, output="history.json", **extra):
        return argparse.Namespace(**dict(dict(output=self.root / output, source_id="one",
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

    def test_invalid_db_preserves_existing_output_and_creates_no_partial_file(self):
        self.sms.write_bytes(b"not sqlite")
        options = self.options(sms_db=self.sms)
        with self.assertRaises(sqlite3.DatabaseError):
            run(options)
        self.assertFalse(options.output.exists())
        self.assertEqual(list(self.root.glob(".airsim-history-*")), [])


if __name__ == "__main__":
    unittest.main()
