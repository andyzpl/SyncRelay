"""Execute the production message-library DDL/SQL locally; this does not run ObjC.

The statements are extracted from Core/SRStore.m so a regression in the real
schema, ordering or guard SQL fails here even without a macOS toolchain.
"""
from pathlib import Path
import re
import sqlite3
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')


def statements(text):
    return re.findall(r'@"([^"\n]+)"', text)


def schema(db):
    section = STORE.split('NSArray *schema = @[', 1)[1].split('];', 1)[0]
    db.execute('PRAGMA foreign_keys=ON')
    for sql in statements(section):
        db.execute(sql)


def open_current(db):
    """Mirror a schema-14 reopen; unsupported versions are never upgraded."""
    version = db.execute('PRAGMA user_version').fetchone()[0]
    if version not in (0, 14):
        raise sqlite3.IntegrityError('Unsupported database schema; fresh schema 14 is required')
    schema(db)
    if db.execute('PRAGMA foreign_key_check').fetchall():
        raise sqlite3.IntegrityError('Database schema has broken foreign keys')


def production(fragment, expected=1):
    found = [sql for sql in statements(STORE)
             if fragment in sql and sql.startswith(('SELECT ', 'INSERT ', 'UPDATE ', 'DELETE '))]
    if len(found) != expected:
        raise AssertionError(f'{len(found)} production statements contain {fragment!r}: {found}')
    return found[0] if expected == 1 else found


def library_section():
    """Entry/version CRUD only; freezing into a task is a separate section."""
    return STORE.split('// Message library:', 1)[1].split('// Message-library tasks:', 1)[0]


LIBRARY_TABLES = ('library_items', 'library_versions', 'media_assets',
                  'media_references', 'content_sources', 'plan_sources', 'library_tasks')


class LibraryModelTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys=ON')
        schema(self.db)
        self.items = production('INSERT INTO library_items')
        self.version_create = production('INTO library_versions(id,item_id,account,ordinal,kind,payload,'
                                         'media_token,captured_at,created_at) VALUES(?,?,?,1,')
        self.version_append = production('INTO library_versions(id,item_id,account,ordinal,kind,payload,'
                                         'media_token,captured_at,created_at) VALUES(?,?,?,?,?')
        self.ordinal = production('COALESCE(MAX(ordinal),0)+1')
        # Editing and task freezing both read the same projection.
        self.lookup = production('SELECT kind,current_version_id FROM library_items WHERE id=? AND account=?', 2)[0]
        self.item_list = production('FROM library_items i WHERE i.account=?')
        self.version_list = production('FROM library_versions WHERE item_id=? AND account=? ORDER BY ordinal')
        self.asset_lookup = production("FROM media_assets WHERE account=? AND scope_kind='message_library'")
        self.source_lookup = production('FROM content_sources WHERE content_id=? AND account=?')

    def tearDown(self):
        self.db.close()

    # helpers -------------------------------------------------------------
    def item(self, identifier, account='account', kind='text', version='v1', created=100):
        self.db.execute(self.items, (identifier, account, kind, created, created, version))

    def version(self, identifier, item, account='account', kind='text', payload='{"text":"hi"}',
                token=None, captured=100):
        self.db.execute(self.version_create, (identifier, item, account, kind, payload, token, captured, captured))

    def append_version(self, identifier, item, account='account', ordinal=2, kind='text',
                       payload='{"text":"edited"}', token=None, captured=100):
        self.db.execute(self.version_append, (identifier, item, account, ordinal, kind, payload, token, captured, captured))

    def content(self, identifier, account='account', message='source', captured=100):
        self.db.execute('INSERT INTO operations_contents'
                        '(id,account,source_group,message_id,configuration,envelope,captured_at)'
                        ' VALUES(?,?,?,?,?,?,?)',
                        (identifier, account, 'mother@chatroom', message, '{}', '{}', captured))

    def count(self, table):
        return self.db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]

    def rows(self, tables):
        return {table: self.db.execute(f'SELECT * FROM {table} ORDER BY rowid').fetchall()
                for table in tables}

    # schema 14 direct initialization -------------------------------------
    def test_schema_14_reopen_keeps_every_current_row(self):
        self.db.execute("INSERT INTO configurations VALUES('account','{}',1)")
        self.db.execute("INSERT INTO operations_preferences VALUES('account',1)")
        self.db.execute("INSERT INTO plans VALUES('plan','account','mother','[]','[]','{}')")
        self.db.execute("INSERT INTO rules VALUES('rule','plan','One',1,5,10)")
        self.db.execute("INSERT INTO allocations VALUES('plan','target@chatroom','rule',0)")
        self.db.execute("INSERT INTO runs VALUES('run','rule','account','running',1,NULL,5,10,'{}')")
        self.db.execute("INSERT INTO deliveries VALUES('delivery','run','target@chatroom',0,'pending',NULL,NULL,NULL)")
        self.db.execute("INSERT INTO source_claims VALUES('account','mother','message','plan')")
        self.content('content')
        self.db.execute("UPDATE operations_contents SET plan_id='plan'")
        legacy = ('configurations', 'operations_preferences', 'plans', 'rules', 'allocations',
                  'runs', 'deliveries', 'source_claims', 'operations_contents')
        before = self.rows(legacy)
        self.db.execute('PRAGMA user_version=14')
        self.db.commit()
        open_current(self.db)
        self.assertEqual(before, self.rows(legacy))
        tables = {row[0] for row in self.db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertTrue(set(LIBRARY_TABLES) <= tables)
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
        self.assertEqual(1, self.db.execute('PRAGMA foreign_keys').fetchone()[0])

    def test_existing_content_source_is_stable_on_reopen(self):
        self.content('one', message='first', captured=170)
        self.db.execute("INSERT INTO content_sources(content_id,account,source_kind,recorded_at) VALUES('one','account','group_sync',170)")
        self.db.execute('PRAGMA user_version=14')
        self.db.commit()
        self.assertEqual([('one', 'group_sync', None, None, 170)],
                         self.db.execute('SELECT content_id,source_kind,library_item_id,'
                                         'library_version_id,recorded_at FROM content_sources').fetchall())
        open_current(self.db)
        self.assertEqual(1, self.count('content_sources'))

    def test_unsupported_schema_is_rejected_without_repair(self):
        self.db.execute('PRAGMA user_version=13')
        self.db.commit()
        with self.assertRaises(sqlite3.IntegrityError):
            open_current(self.db)
        self.assertEqual(13, self.db.execute('PRAGMA user_version').fetchone()[0])

    # versions ------------------------------------------------------------
    def test_versions_are_immutable_in_the_database(self):
        self.item('item')
        self.version('v1', 'item')
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE library_versions SET payload='{\"text\":\"rewritten\"}' WHERE id='v1'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM library_versions WHERE id='v1'")
        self.assertEqual([('v1', 1, '{"text":"hi"}')],
                         [(row[0], row[1], row[3]) for row in self.db.execute(self.version_list, ('item', 'account'))])

    def test_editing_appends_an_ordinal_and_keeps_the_old_version(self):
        self.item('item')
        self.version('v1', 'item')
        self.assertEqual(2, self.db.execute(self.ordinal, ('item',)).fetchone()[0])
        self.append_version('v2', 'item')
        self.db.execute('UPDATE library_items SET current_version_id=? WHERE id=? AND account=?',
                        ('v2', 'item', 'account'))
        self.assertEqual([('v1', 1, '{"text":"hi"}'), ('v2', 2, '{"text":"edited"}')],
                         [(row[0], row[1], row[3]) for row in self.db.execute(self.version_list, ('item', 'account'))])
        self.assertEqual('v2', self.db.execute(self.lookup, ('item', 'account')).fetchone()[1])
        self.assertEqual(3, self.db.execute(self.ordinal, ('item',)).fetchone()[0])
        with self.assertRaises(sqlite3.IntegrityError):
            self.append_version('v3', 'item', ordinal=2)

    # account isolation ---------------------------------------------------
    def test_entries_versions_and_assets_are_account_scoped(self):
        self.item('item', account='account')
        self.version('v1', 'item', account='account')
        self.item('other-item', account='other', version='other-v1')
        self.assertIsNone(self.db.execute(self.lookup, ('item', 'other')).fetchone())
        self.assertEqual([], self.db.execute(self.version_list, ('item', 'other')).fetchall())
        self.assertEqual(['item'], [row[0] for row in self.db.execute(self.item_list, ('account', 10, 0))])
        self.assertEqual(['other-item'], [row[0] for row in self.db.execute(self.item_list, ('other', 10, 0))])
        self.db.execute('INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)',
                        ('token-1', 'account', 'message_library', 'a' * 64, 'b' * 64, 10, 2, 3, 'png', 100))
        self.assertEqual(1, len(self.db.execute(self.asset_lookup, ('account', 'a' * 64, 'b' * 64)).fetchall()))
        self.assertIsNone(self.db.execute(self.asset_lookup, ('other', 'a' * 64, 'b' * 64)).fetchone())

    def test_identical_bytes_share_one_asset_but_never_merge_entries(self):
        scope, digest = 'a' * 64, 'b' * 64
        self.db.execute('INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)',
                        ('token-1', 'account', 'message_library', scope, digest, 10, 2, 3, 'png', 100))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)',
                            ('token-2', 'account', 'message_library', scope, digest, 10, 2, 3, 'png', 101))
        # Same bytes under another account and other bytes under the same account are distinct.
        self.db.execute('INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)',
                        ('token-3', 'other', 'message_library', scope, digest, 10, 2, 3, 'png', 101))
        self.db.execute('INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)',
                        ('token-4', 'account', 'message_library', scope, 'c' * 64, 10, 2, 3, 'png', 102))
        self.item('first-image', kind='image', version='first-v1')
        self.item('second-image', kind='image', version='second-v1')
        self.version('first-v1', 'first-image', kind='image', payload='{}', token='token-1')
        self.version('second-v1', 'second-image', kind='image', payload='{}', token='token-1')
        for owner_kind, owner_id in (('library_item', 'first-image'), ('library_version', 'first-v1'),
                                     ('library_item', 'second-image'), ('library_version', 'second-v1')):
            self.db.execute('INSERT INTO media_references VALUES(?,?,?,?,?)',
                            ('account', 'token-1', owner_kind, owner_id, 100))
        self.assertEqual(2, self.count('library_items'))
        self.assertEqual(2, self.count('library_versions'))
        self.assertEqual(4, self.count('media_references'))
        self.assertEqual(1, self.db.execute('SELECT COUNT(*) FROM media_assets WHERE token=?',
                                            ('token-1',)).fetchone()[0])

    def test_library_image_registration_requires_exact_account_and_metadata(self):
        lookup = production("SELECT token FROM media_assets WHERE token=? AND account=? AND scope_kind='message_library'")
        values = ('token', 'account', 'a' * 64, 'b' * 64, 10, 2, 3, 'png')
        self.assertIsNone(self.db.execute(lookup, values).fetchone())
        self.db.execute('INSERT INTO media_assets VALUES(?,?,?,?,?,?,?,?,?,?)',
                        (values[0], values[1], 'message_library', *values[2:], 100))
        self.assertEqual(('token',), self.db.execute(lookup, values).fetchone())
        for index, different in enumerate(('unregistered-token', 'other', 'c' * 64, 'd' * 64,
                                            11, 4, 5, 'jpeg')):
            with self.subTest(field=index):
                changed = list(values)
                changed[index] = different
                self.assertIsNone(self.db.execute(lookup, changed).fetchone())
        self.db.execute("UPDATE media_assets SET scope_kind='group_source'")
        self.assertIsNone(self.db.execute(lookup, values).fetchone())

    def test_image_registration_is_checked_before_creating_references(self):
        section = library_section()
        validate = section.split('- (NSString *)libraryTokenForPayload:', 1)[1].split('\n}', 1)[0]
        self.assertLess(validate.index('SELECT token FROM media_assets WHERE token=? AND account=?'),
                        validate.index('[self.imageAssets dataForPayload:'))
        self.assertIn('Library image is not registered with matching metadata for this account', validate)
        for method, insert in (('createLibraryItemForAccount:', 'INSERT INTO library_items'),
                               ('appendLibraryVersion:', 'INSERT INTO library_versions')):
            body = section.split(f'- (NSString *){method}', 1)[1].split('\n}', 1)[0]
            with self.subTest(method=method):
                self.assertLess(body.index('[self libraryTokenForPayload:'), body.index(insert))
                self.assertLess(body.index('[self libraryTokenForPayload:'),
                                body.index('[self recordLibraryReferences:'))

    def test_stale_asset_guard_detects_every_durable_owner(self):
        owners = production('SELECT 1 FROM media_references WHERE token=? UNION ALL')
        self.assertIsNone(self.db.execute(owners, ('token',) * 3).fetchone())
        self.item('image', kind='image', version='image-v1')
        self.version('image-v1', 'image', kind='image', payload='{}', token='different-token')
        self.db.execute("INSERT INTO plans VALUES('plan','account','','[]','[]','{}')")
        self.db.execute("INSERT INTO rules VALUES('rule','plan','Library',1,5,10)")
        cases = [(kind, "INSERT INTO media_references VALUES('account','token',?,?,100)",
                  (kind, f'owner-{kind}'))
                 for kind in ('library_item', 'library_version', 'plan', 'run', 'history')]
        cases.extend([
            ('cross-account-reference',
             "INSERT INTO media_references VALUES('other','token','plan','other-plan',100)", ()),
            ('version-without-reference',
             'INSERT INTO library_versions VALUES(?,?,?,?,?,?,?,?,?)',
             ('image-v2', 'image', 'account', 2, 'image', '{}', 'token', 101, 101)),
            ('task-without-reference',
             'INSERT INTO library_tasks(id,account,confirmation_id,item_id,version_id,plan_id,rule_id,'
             'frozen_snapshot,frozen_sha256,media_token,target_sha256,target_count,created_at)'
             " VALUES('task','account','confirm','image','image-v1','plan','rule','{}','digest','token','targets',1,100)", ()),
        ])
        for name, sql, values in cases:
            with self.subTest(owner=name):
                self.db.execute('SAVEPOINT owner_case')
                try:
                    self.db.execute(sql, values)
                    self.assertEqual((1,), self.db.execute(owners, ('token',) * 3).fetchone())
                    self.assertIsNone(self.db.execute(owners, ('unrelated-token',) * 3).fetchone())
                finally:
                    self.db.execute('ROLLBACK TO owner_case')
                    self.db.execute('RELEASE owner_case')

    def test_stale_asset_replacement_keeps_referenced_rows(self):
        owners = production('SELECT 1 FROM media_references WHERE token=? UNION ALL')
        self.db.execute("INSERT INTO media_assets VALUES('token','account','message_library','scope','digest',10,2,3,'png',100)")
        self.item('image', kind='image', version='image-v1')
        self.version('image-v1', 'image', kind='image', payload='{}', token='token')
        self.db.execute("INSERT INTO media_references VALUES('account','token','library_version','image-v1',100)")
        before = self.rows(LIBRARY_TABLES)
        # Execute the product's owner query under the same write lock. This is
        # SQLite coverage, not execution of the Objective-C branch or file I/O.
        self.db.commit()
        self.db.execute('BEGIN IMMEDIATE')
        if self.db.execute(owners, ('token',) * 3).fetchone():
            self.db.rollback()
        else:
            self.fail('A referenced asset must not reach the replacement write')
        self.assertEqual(before, self.rows(LIBRARY_TABLES))
        save = library_section().split('- (NSDictionary *)saveLibraryImageData:', 1)[1].split('\n}', 1)[0]
        self.assertLess(save.index(owners), save.index('[self.imageAssets saveData:'))
        self.assertLess(save.index(owners), save.index('DELETE FROM media_assets'))
        self.assertIn(f'SRRequire([self query:@"{owners}"\n'
                      '                values:@[token, token, token]].count == 0,', save)
        self.assertIn('Referenced library image is unavailable; its stored identity was retained', save)

    def test_unreferenced_stale_asset_remains_replaceable(self):
        owners = production('SELECT 1 FROM media_references WHERE token=? UNION ALL')
        insert = production('INSERT INTO media_assets(token,account,scope_kind,scope_sha256,sha256,byte_count,')
        remove = production('DELETE FROM media_assets WHERE token=? AND account=?')
        old = ('old-token', 'account', 'scope', 'digest', 10, 2, 3, 'png', 100)
        self.db.execute(insert, old)
        self.assertIsNone(self.db.execute(owners, ('old-token',) * 3).fetchone())
        self.db.execute(remove, ('old-token', 'account'))
        self.db.execute(insert, ('new-token', *old[1:]))
        self.assertEqual([('new-token',)], self.db.execute('SELECT token FROM media_assets').fetchall())
        self.assertEqual(0, self.count('media_references'))
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())

    def test_media_reference_owner_kinds_are_bounded_and_unique(self):
        allowed = ('library_item', 'library_version', 'plan', 'run', 'history')
        for kind in allowed:
            self.db.execute('INSERT INTO media_references VALUES(?,?,?,?,?)',
                            ('account', 'token', kind, f'owner-{kind}', 100))
        self.assertEqual(len(allowed), self.count('media_references'))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO media_references VALUES(?,?,?,?,?)',
                            ('account', 'token', 'plan', 'owner-plan', 100))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO media_references VALUES(?,?,?,?,?)',
                            ('account', 'token', 'unknown', 'owner-unknown', 100))

    def test_source_identity_is_bounded_and_foreign_key_checked(self):
        self.content('content')
        self.assertEqual(0, self.count('content_sources'))
        self.db.execute("INSERT INTO content_sources VALUES('content','account','message_library',NULL,NULL,100)")
        self.assertEqual('message_library',
                         self.db.execute(self.source_lookup, ('content', 'account')).fetchone()[0])
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO content_sources VALUES('missing','account','group_sync',NULL,NULL,100)")
        self.db.execute("DELETE FROM content_sources")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO content_sources VALUES('content','account','imported',NULL,NULL,100)")

    # no coupling to sending ---------------------------------------------
    def test_library_writes_leave_group_sync_ledgers_untouched(self):
        self.content('content')
        self.db.execute("INSERT INTO plans VALUES('plan','account','mother','[]','[]','{}')")
        self.db.execute("INSERT INTO rules VALUES('rule','plan','One',1,5,10)")
        self.db.execute("INSERT INTO runs VALUES('run','rule','account','running',1,NULL,5,10,'{}')")
        self.db.execute("INSERT INTO deliveries VALUES('delivery','run','target@chatroom',0,'pending',NULL,NULL,NULL)")
        self.db.execute("INSERT INTO source_claims VALUES('account','mother','message','plan')")
        ledger = ('plans', 'rules', 'allocations', 'runs', 'deliveries', 'attempts', 'source_claims',
                  'operations_contents', 'content_sources')
        before = self.rows(ledger)
        self.item('item', created=200)
        self.version('v1', 'item', captured=200)
        self.assertEqual(before, self.rows(ledger))

    def test_failed_library_write_rolls_back_every_row(self):
        self.db.execute("CREATE TRIGGER fail_version BEFORE INSERT ON library_versions"
                        " BEGIN SELECT RAISE(ABORT,'fault'); END")
        self.db.commit()
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('BEGIN IMMEDIATE')
            try:
                self.item('item')
                self.version('v1', 'item')
            except sqlite3.IntegrityError:
                self.db.execute('ROLLBACK')
                raise
        self.assertEqual(0, self.count('library_items'))
        self.assertEqual(0, self.count('library_versions'))
        self.assertEqual(0, self.count('media_references'))

    def test_library_code_cannot_reach_plans_runs_claims_or_sending(self):
        section = library_section()
        for forbidden in ('INSERT INTO plans', 'INSERT INTO source_claims', 'INSERT INTO runs',
                          'INSERT INTO deliveries', 'INSERT INTO attempts', 'startRule',
                          'claimNextForRun', 'SRRunner', 'SRWeChatTextSendAdapter',
                          'SRWeChatImageSendHost'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, section)
        for required in ('INSERT INTO library_items', 'INSERT INTO library_versions',
                         'INSERT OR IGNORE INTO media_references', 'INSERT INTO media_assets'):
            with self.subTest(required=required):
                self.assertIn(required, section)


if __name__ == '__main__':
    unittest.main()
