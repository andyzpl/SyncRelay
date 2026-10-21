"""Execute production schema/SQL invariants locally, not the Objective-C owner."""
from pathlib import Path
import re
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')


def statements(section):
    return re.findall(r'@"([^"\n]+)"', section)


def schema(db):
    section = STORE.split('NSArray *schema = @[', 1)[1].split('];', 1)[0]
    db.execute('PRAGMA foreign_keys=ON')
    for sql in statements(section):
        db.execute(sql)


def additive_migration(db):
    """Run production DDL/check/version SQL in one SQLite transaction, not ObjC."""
    section = STORE.split('if (version < 11) {', 1)[1].split('return @YES;', 1)[0]
    check, version = (sql for sql in statements(section) if sql.startswith('PRAGMA '))
    db.execute('PRAGMA foreign_keys=ON')
    try:
        db.execute('BEGIN IMMEDIATE')
        schema(db)
        if db.execute(check).fetchall():
            raise sqlite3.IntegrityError('Migration found broken foreign keys')
        db.execute(version)
        db.commit()
    except sqlite3.Error:
        db.rollback()
        raise


def method_sql(start, end):
    section = STORE.split(start, 1)[1].split(end, 1)[0]
    return [sql for sql in statements(section)
            if sql.startswith(('INSERT ', 'UPDATE ', 'SELECT ', 'DELETE '))]


class OperationsSchemaTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        schema(self.db)

    def tearDown(self):
        self.db.close()

    def content(self, identifier, account='account', message='source', archived=None):
        self.db.execute('INSERT INTO operations_contents'
                        '(id,account,source_group,message_id,configuration,envelope,captured_at,archived_at)'
                        ' VALUES(?,?,?,?,?,?,?,?)',
                        (identifier, account, 'mother@chatroom', message, '{}', '{}', 100, archived))

    def seed_run(self):
        self.db.execute("INSERT INTO plans VALUES('plan','account','mother','[]','[]','{}')")
        self.db.execute("INSERT INTO rules VALUES('rule','plan','One',1,5,10)")
        self.db.execute("INSERT INTO runs VALUES('run','rule','account','running',1,NULL,5,10,'{}')")
        self.db.execute("INSERT INTO deliveries VALUES('first','run','a',0,'submitting','attempt',NULL,NULL)")
        self.db.execute("INSERT INTO attempts VALUES('attempt','first',1,NULL,'submitting',NULL,NULL)")
        self.db.execute("INSERT INTO deliveries VALUES('second','run','b',1,'pending',NULL,NULL,NULL)")

    def rows(self, tables):
        return {table: self.db.execute(f'SELECT * FROM {table} ORDER BY rowid').fetchall()
                for table in tables}

    def seed_ledgers(self):
        self.seed_run()
        self.db.execute("INSERT INTO configurations VALUES('account','{}',1)")
        self.db.execute("INSERT INTO operations_preferences VALUES('account',1)")
        self.db.execute("INSERT INTO source_claims VALUES('account','mother','message','plan')")
        self.db.execute("INSERT INTO native_attempt_claims VALUES('first','attempt',2)")
        self.db.execute("INSERT INTO small_group_runs VALUES('run',1)")
        self.db.execute("INSERT INTO text_experiments VALUES('account','mother','text-source','a',1)")
        self.db.execute("INSERT INTO image_experiments VALUES('account','mother','image-source','b',1)")
        self.db.execute("INSERT INTO submission_receipts VALUES('first','attempt',2)")

    def legacy_tables(self):
        return ('configurations', 'operations_preferences', 'plans', 'rules', 'runs',
                'allocations', 'deliveries', 'attempts', 'source_claims',
                'native_attempt_claims', 'small_group_runs', 'text_experiments',
                'image_experiments', 'submission_receipts')

    def test_schema_11_guard_version_and_tables_agree(self):
        self.assertIn('version >= 0 && version <= 11', STORE)
        self.assertIn('if (version < 11) {', STORE)
        self.assertEqual(['PRAGMA user_version=11'],
                         [sql for sql in statements(STORE) if sql.startswith('PRAGMA user_version=')])
        additive_migration(self.db)
        self.assertEqual(11, self.db.execute('PRAGMA user_version').fetchone()[0])
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue({'operations_preferences', 'operations_contents',
                         'operations_cancellations', 'operations_legacy_adoptions'} <= tables)
        self.assertEqual(1, self.db.execute('PRAGMA foreign_keys').fetchone()[0])

    def test_one_current_content_per_account(self):
        self.content('one')
        with self.assertRaises(sqlite3.IntegrityError):
            self.content('two', message='new-source')
        self.content('other', account='other')
        self.assertEqual(2, self.db.execute('SELECT COUNT(*) FROM operations_contents').fetchone()[0])

    def test_archiving_does_not_release_source_identity(self):
        self.content('one', archived=200)
        self.content('new', message='new-source')
        with self.assertRaises(sqlite3.IntegrityError):
            self.content('duplicate', message='source', archived=300)

    def test_plan_link_is_unique_and_foreign_key_checked(self):
        self.content('one')
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE operations_contents SET plan_id='missing'")

    def test_cancel_sql_only_revokes_pending(self):
        self.seed_run()
        queries = method_sql('- (BOOL)cancelOperationsRun:', '- (NSDictionary *)operationsCancellationForRun:')
        update = next(sql for sql in queries if sql.startswith('UPDATE deliveries'))
        self.db.execute(update, ('run',))
        rows = self.db.execute('SELECT state,attempt_id FROM deliveries ORDER BY position').fetchall()
        self.assertEqual([('submitting', 'attempt'), ('cancelled', None)], rows)
        self.assertEqual('submitting', self.db.execute('SELECT state FROM attempts').fetchone()[0])

    def test_cancel_retains_account_slot_until_drained(self):
        self.seed_run()
        self.db.execute("INSERT INTO operations_cancellations VALUES('run',2,NULL)")
        self.db.execute("UPDATE runs SET state='paused' WHERE id='run'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO runs VALUES('second','rule','account','running',3,NULL,5,10,'{}')")
        # The production finalizer writes ended + ended_at and drained_at together.
        queries = method_sql('- (void)finishOperationsCancellationUnchecked:', '- (BOOL)cancelOperationsRun:')
        self.db.execute("UPDATE deliveries SET state='uncertain' WHERE id='first'")
        for sql in queries:
            if sql.startswith('UPDATE '):
                self.db.execute(sql, (4, 'run'))
        self.assertEqual(('ended', 4), self.db.execute('SELECT state,ended_at FROM runs').fetchone())
        self.assertEqual(4, self.db.execute('SELECT drained_at FROM operations_cancellations').fetchone()[0])
        self.db.execute("INSERT INTO runs VALUES('second','rule','account','running',5,NULL,5,10,'{}')")

    def test_preferences_are_account_scoped_and_boolean(self):
        self.db.execute("INSERT INTO operations_preferences VALUES('one',1)")
        self.assertIsNone(self.db.execute("SELECT enabled FROM operations_preferences WHERE account='other'").fetchone())
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO operations_preferences VALUES('bad',2)")

    def test_additive_schema_preserves_history_and_claims(self):
        self.seed_ledgers()
        self.db.execute('DROP TABLE operations_legacy_adoptions')
        self.db.execute('DROP TABLE operations_cancellations')
        self.db.execute('DROP TABLE operations_contents')
        self.db.execute('PRAGMA user_version=9')
        self.db.commit()
        before = self.rows(self.legacy_tables())
        additive_migration(self.db)
        self.assertEqual(before, self.rows(self.legacy_tables()))
        self.assertEqual(11, self.db.execute('PRAGMA user_version').fetchone()[0])
        self.assertEqual('submitting', self.db.execute("SELECT state FROM deliveries WHERE id='first'").fetchone()[0])
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())

    def test_schema_10_upgrade_keeps_frozen_content_and_cancellation(self):
        self.seed_ledgers()
        self.content('content')
        self.db.execute("UPDATE operations_contents SET plan_id='plan'")
        self.db.execute("INSERT INTO operations_cancellations VALUES('run',3,NULL)")
        self.db.execute('DROP TABLE operations_legacy_adoptions')
        self.db.execute('PRAGMA user_version=10')
        self.db.commit()
        tables = self.legacy_tables() + ('operations_contents', 'operations_cancellations')
        before = self.rows(tables)
        additive_migration(self.db)
        self.assertEqual(before, self.rows(tables))
        self.assertEqual(11, self.db.execute('PRAGMA user_version').fetchone()[0])
        self.assertEqual([], self.db.execute('SELECT * FROM operations_legacy_adoptions').fetchall())
        # Reopening/reapplying the additive DDL never resets old rows or preferences.
        additive_migration(self.db)
        self.assertEqual(before, self.rows(tables))

    def test_failed_schema_upgrade_rolls_back_tables_and_version(self):
        self.seed_ledgers()
        self.db.execute('DROP TABLE operations_legacy_adoptions')
        self.db.execute('DROP TABLE operations_cancellations')
        self.db.execute('DROP TABLE operations_contents')
        self.db.execute('PRAGMA user_version=9')
        self.db.commit()
        self.db.execute('PRAGMA foreign_keys=OFF')
        self.db.execute("INSERT INTO allocations VALUES('missing','orphan','rule',0)")
        self.db.commit()
        before = self.rows(self.legacy_tables())
        with self.assertRaises(sqlite3.IntegrityError):
            additive_migration(self.db)
        self.assertEqual(9, self.db.execute('PRAGMA user_version').fetchone()[0])
        self.assertEqual(before, self.rows(self.legacy_tables()))
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertFalse({'operations_contents', 'operations_cancellations',
                          'operations_legacy_adoptions'} & tables)

    def test_content_and_plan_link_transaction_rollback(self):
        self.content('content')
        self.db.commit()
        self.db.execute("CREATE TRIGGER fail_link BEFORE UPDATE OF plan_id ON operations_contents BEGIN SELECT RAISE(ABORT,'fault'); END")
        with self.assertRaises(sqlite3.IntegrityError), self.db:
            self.db.execute("INSERT INTO plans VALUES('new','account','mother','[]','[]','{}')")
            self.db.execute("INSERT INTO source_claims VALUES('account','mother','message','new')")
            self.db.execute("UPDATE operations_contents SET plan_id='new'")
        self.assertEqual(0, self.db.execute('SELECT COUNT(*) FROM plans').fetchone()[0])
        self.assertEqual(0, self.db.execute('SELECT COUNT(*) FROM source_claims').fetchone()[0])
        self.assertEqual(1, self.db.execute('SELECT COUNT(*) FROM operations_contents').fetchone()[0])

    def test_legacy_adoption_requires_valid_links_and_unique_run(self):
        self.seed_run()
        self.content('content', archived=3)
        self.content('second', message='another')
        self.db.execute("INSERT INTO operations_legacy_adoptions VALUES('content','run',4)")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO operations_legacy_adoptions VALUES('second','run',5)")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO operations_legacy_adoptions VALUES('missing','missing',5)")
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())

    def test_legacy_adoption_rollback_preserves_original_attempts(self):
        self.seed_run()
        self.db.execute("INSERT INTO source_claims VALUES('account','mother','message','plan')")
        self.db.execute("INSERT INTO native_attempt_claims VALUES('first','attempt',2)")
        tables = ('plans', 'rules', 'runs', 'allocations', 'deliveries', 'attempts',
                  'source_claims', 'native_attempt_claims')
        before = {table: self.db.execute(f'SELECT * FROM {table}').fetchall() for table in tables}
        self.db.commit()
        self.db.execute("CREATE TRIGGER fail_adoption BEFORE INSERT ON operations_legacy_adoptions BEGIN SELECT RAISE(ABORT,'fault'); END")
        queries = method_sql('- (NSString *)adoptLegacyOperationsRun:', '- (NSString *)planForOperationsContent:')
        insert_content = next(sql for sql in queries if sql.startswith('INSERT INTO operations_contents'))
        insert_adoption = next(sql for sql in queries if sql.startswith('INSERT INTO operations_legacy_adoptions'))
        with self.assertRaises(sqlite3.IntegrityError), self.db:
            self.db.execute(insert_content, ('content', 'account', 'mother', 'message', '{}', '{}', 'plan'))
            self.db.execute(insert_adoption, ('content', 'run', 4))
        self.assertEqual(0, self.db.execute('SELECT COUNT(*) FROM operations_contents').fetchone()[0])
        self.assertEqual(before, {table: self.db.execute(f'SELECT * FROM {table}').fetchall() for table in tables})


if __name__ == '__main__':
    unittest.main()
