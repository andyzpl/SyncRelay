"""Execute the production message-library task DDL/SQL locally; this does not run ObjC.

Statements are extracted from Core/SRStore.m so a regression in the freeze
schema, an idempotency key, a guard order or an immutability trigger fails here
even without a macOS toolchain. The ObjC semantics (account checks, argument
validation) are covered by tests/library_task_test.m, which is CI-only.
"""
from pathlib import Path
import hashlib
import json
import re
import sqlite3
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / 'Core/SRStore.m').read_text(encoding='utf-8')
TOKEN = '11111111-2222-3333-4444-555555555555'
TARGETS = ['one@chatroom', 'two@chatroom', 'three@chatroom']


def statements(text):
    return re.findall(r'@"([^"\n]+)"', text)


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def target_digest(targets):
    """Mirror SRTargetDigest: ordered ids joined by a newline."""
    return digest('\n'.join(targets))


def schema(db):
    section = STORE.split('NSArray *schema = @[', 1)[1].split('];', 1)[0]
    for sql in statements(section):
        db.execute(sql)


def reopen_current(db):
    """Reapply current trigger definitions only for schema 14 databases."""
    version = db.execute('PRAGMA user_version').fetchone()[0]
    if version != 14:
        raise sqlite3.IntegrityError('Unsupported database schema; fresh schema 14 is required')
    schema(db)
    if db.execute('PRAGMA foreign_key_check').fetchall():
        raise sqlite3.IntegrityError('Database schema has broken foreign keys')


def matches(fragment):
    return [sql for sql in statements(STORE) if fragment in sql
            and sql.startswith(('SELECT ', 'INSERT ', 'UPDATE ', 'DELETE '))]


def stmt(fragment, last=True):
    """One production statement. `last` picks the newest writer for a shared query."""
    found = matches(fragment)
    if not found:
        raise AssertionError(f'no production statement contains {fragment!r}')
    return found[-1] if last else found[0]


def count(fragment):
    return len(matches(fragment))


def task_section():
    return STORE.split('// Message-library tasks:', 1)[1].split('#pragma mark - Shared media budget', 1)[0]


class TaskFixture(object):
    """Runs the production row order of createLibraryTask/startLibraryTask."""

    def __init__(self, db):
        self.db = db
        self.insert_item = stmt('INSERT INTO library_items')
        self.insert_version = stmt('INTO library_versions(id,item_id,account,ordinal,kind,payload,'
                                  'media_token,captured_at,created_at) VALUES(?,?,?,1,')
        self.insert_plan = stmt('INSERT INTO plans(id,account,source_group,senders,types,snapshot)')
        self.insert_plan_source = stmt('INSERT INTO plan_sources(plan_id,account,source_kind,'
                                       'library_item_id,library_version_id,target_sha256,recorded_at)')
        self.insert_rule = stmt('INSERT INTO rules(id,plan_id,name,position,minimum,maximum)')
        self.insert_allocation = stmt('INSERT INTO allocations(plan_id,target,rule_id,position)')
        self.insert_task = stmt('INSERT INTO library_tasks(id,account,confirmation_id,item_id,version_id,')
        self.by_confirmation = stmt('SELECT t.id,t.item_id,t.version_id,t.target_sha256,t.target_count,'
                                    't.origin_task_id,r.minimum,r.maximum FROM library_tasks t '
                                    'JOIN rules r ON r.id=t.rule_id WHERE t.account=? '
                                    'AND t.confirmation_id=?')
        self.occupancy = stmt('SELECT t.id,t.run_id,x.state,t.started_at FROM library_tasks t '
                              'JOIN runs x ON x.id=t.run_id WHERE t.account=?')
        self.by_id = stmt('SELECT * FROM library_tasks WHERE id=? AND account=?')
        self.by_run = stmt('SELECT id,account FROM library_tasks WHERE run_id=?')
        self.source_kind = stmt('SELECT source_kind FROM plan_sources WHERE plan_id=?')
        self.plan_source = stmt("SELECT plan_id FROM plan_sources WHERE plan_id=? "
                                "AND source_kind='message_library'")
        self.allocations = stmt('SELECT target,position FROM allocations WHERE rule_id=? '
                                'ORDER BY position ASC')
        self.insert_run = stmt("INSERT INTO runs(id,rule_id,account,state,started_at,minimum,maximum,"
                               "snapshot) VALUES(?,?,?,'awaiting_resume'")
        self.insert_delivery = stmt('INSERT INTO deliveries(id,run_id,target,position,state) '
                                    "VALUES(?,?,?,?,'pending')")
        self.attach_run = stmt('UPDATE library_tasks SET run_id=?')
        self.plan_reference = stmt('INSERT OR IGNORE INTO media_references(account,token,owner_kind,'
                                   "owner_id,created_at) VALUES(?,?,'plan'")
        self.history_reference = stmt('INSERT OR IGNORE INTO media_references(account,token,owner_kind,'
                                      "owner_id,created_at) VALUES(?,?,'history'")
        self.run_reference = stmt('INSERT OR IGNORE INTO media_references(account,token,owner_kind,'
                                  "owner_id,created_at) VALUES(?,?,'run'")
        self.active_content = stmt('SELECT id FROM operations_contents WHERE account=? '
                                   'AND archived_at IS NULL')
        self.active_run = stmt('SELECT id FROM runs WHERE account=? AND state IN '
                               "('running','paused','awaiting_resume')")
        self.legacy_projection = stmt('FROM runs x JOIN rules r ON r.id=x.rule_id '
                                      'WHERE x.account=?')

    # fixture helpers -----------------------------------------------------
    def item(self, account='account', identifier='item', kind='text', captured=100):
        version = f'{identifier}-v1'
        payload = json.dumps({'text': 'hi'}, separators=(',', ':'))
        self.db.execute(self.insert_item, (identifier, account, kind, captured, captured, version))
        self.db.execute(self.insert_version, (version, identifier, account, kind, payload, None,
                                              captured, captured))
        return version

    def snapshot(self, account='account', identifier='item', version='item-v1', kind='text'):
        body = {'text': 'hi'} if kind == 'text' else {
            'mediaReference': TOKEN, 'snapshotSchema': 1, 'scopeSHA256': 'a' * 64,
            'sha256': 'b' * 64, 'byteCount': 10, 'pixelWidth': 2, 'pixelHeight': 3, 'format': 'png'}
        return json.dumps({'type': kind, 'payload': body, 'account': account,
                           'sourceKind': 'message_library', 'itemID': identifier,
                           'versionID': version, 'generatedByRelay': False},
                          sort_keys=True, separators=(',', ':'))

    def confirm(self, confirmation, account='account', identifier='item', version=None,
                targets=None, snapshot=None, minimum=5.0, maximum=10.0, origin=None):
        """Mirror createLibraryTaskForAccount: resolve, replay, then freeze."""
        if version is None:
            current = self.db.execute('SELECT current_version_id FROM library_items WHERE id=? '
                                      'AND account=?', (identifier, account)).fetchone()
            if current is None:
                raise ValueError('library entry unavailable for this account')
            version = current[0]
        targets = list(targets or TARGETS)
        replay = self.replay(confirmation, account, identifier, version, targets, minimum, maximum, origin)
        if replay:
            return replay
        frozen = snapshot or self.snapshot(account, identifier, version)
        key = f'{account}:{confirmation}'
        plan, rule, task = f'plan-{key}', f'rule-{key}', f'task-{key}'
        self.db.execute(self.insert_plan, (plan, account, json.dumps(['text']), frozen))
        self.db.execute(self.insert_plan_source,
                        (plan, account, identifier, version, target_digest(targets), 100.0))
        self.db.execute(self.insert_rule, (rule, plan, minimum, maximum))
        for position, target in enumerate(targets):
            self.db.execute(self.insert_allocation, (plan, target, rule, position))
        self.db.execute(self.insert_task, (task, account, confirmation, identifier, version, plan, rule,
                                           frozen, digest(frozen), TOKEN, target_digest(targets),
                                           len(targets), origin, 100.0))
        self.db.execute(self.plan_reference, (account, TOKEN, plan, 100.0))
        self.db.execute(self.history_reference, (account, TOKEN, task, 100.0))
        return task

    def replay(self, confirmation, account, identifier, version, targets, minimum, maximum, origin):
        """The whole request must match: content, ordered targets, interval, origin.

        The production comparison is ObjC; this executes the same lookup statement
        so the SQL shape the comparison depends on is checked here too.
        """
        row = self.db.execute(self.by_confirmation, (account, confirmation)).fetchone()
        if row is None:
            return None
        (task, item, stored_version, target_sha, target_count, stored_origin,
         stored_minimum, stored_maximum) = row
        if item != identifier:
            raise ValueError('confirmation reused for a different library entry')
        if stored_version != version:
            raise ValueError('confirmation reused for a different library version')
        if target_count != len(targets) or target_sha != target_digest(targets):
            raise ValueError('confirmation reused for a different target scope or order')
        if abs(stored_minimum - minimum) >= 1e-9 or abs(stored_maximum - maximum) >= 1e-9:
            raise ValueError('confirmation reused with a different send interval')
        if stored_origin != origin:
            raise ValueError('confirmation reused by a different operation or origin task')
        return task

    def resend(self, task, confirmation, account='account'):
        """Mirror resendLibraryTask: the key is bound to this origin task."""
        fields = self.frozen(task, account)
        targets = [target for target, _ in self.db.execute(self.allocations, (fields['rule_id'],))]
        rule = self.db.execute('SELECT minimum,maximum FROM rules WHERE id=?', (fields['rule_id'],)).fetchone()
        replay = self.replay(confirmation, account, fields['item_id'], fields['version_id'], targets,
                             rule[0], rule[1], task)
        if replay:
            return replay
        return self.confirm(confirmation, account=account, identifier=fields['item_id'],
                            version=fields['version_id'], targets=targets,
                            snapshot=fields['frozen_snapshot'], minimum=rule[0], maximum=rule[1],
                            origin=task)

    def frozen(self, task, account='account'):
        row = self.db.execute(self.by_id, (task, account)).fetchone()
        if row is None:
            raise ValueError('task unavailable for this account')
        columns = [column[0] for column in self.db.execute('SELECT * FROM library_tasks LIMIT 0').description]
        return dict(zip(columns, row))

    def start(self, task, account='account'):
        fields = self.frozen(task, account)
        if fields['run_id'] is not None:
            return fields['run_id']
        targets = [target for target, _ in self.db.execute(self.allocations, (fields['rule_id'],))]
        run = f'run-{task}'
        self.db.execute(self.insert_run, (run, fields['rule_id'], account, 100.0, 5.0, 10.0,
                                          fields['frozen_snapshot']))
        for position, target in enumerate(targets):
            self.db.execute(self.insert_delivery, (f'delivery-{task}-{position}', run, target, position))
        self.db.execute(self.attach_run, (run, 100.0, task, account))
        self.db.execute(self.run_reference, (account, TOKEN, run, 100.0))
        return run

    def count(self, table):
        return self.db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]


class LibraryTaskTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(':memory:')
        self.db.execute('PRAGMA foreign_keys=ON')
        schema(self.db)
        self.fx = TaskFixture(self.db)

    def tearDown(self):
        self.db.close()

    # 1. idempotency ------------------------------------------------------
    def test_repeated_confirmation_returns_one_task(self):
        self.fx.item()
        first = self.fx.confirm('confirm-1')
        second = self.fx.confirm('confirm-1')
        self.assertEqual(first, second)
        self.assertEqual(1, self.fx.count('library_tasks'))
        self.assertEqual(1, self.fx.count('plans'))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute(self.fx.insert_task, ('other-task', 'account', 'confirm-1', 'item', 'item-v1',
                                                  'plan-other', 'rule-other', '{}', digest('{}'), None,
                                                  target_digest(TARGETS), 3, None, 100.0))
        # A reused key may never silently point at another version.
        with self.assertRaises(ValueError):
            self.fx.confirm('confirm-1', version='item-v2')
        # The same key with any other request is refused, never re-pointed.
        for label, kwargs in (
                ('targets', {'targets': ['one@chatroom', 'two@chatroom', 'other@chatroom']}),
                ('order', {'targets': list(reversed(TARGETS))}),
                ('count', {'targets': TARGETS[:2]}),
                ('minimum', {'minimum': 6.0}),
                ('maximum', {'maximum': 20.0}),
                ('origin', {'origin': 'some-other-task'})):
            with self.subTest(change=label):
                with self.assertRaises(ValueError):
                    self.fx.confirm('confirm-1', **kwargs)
        self.assertEqual(1, self.fx.count('library_tasks'))
        self.assertEqual(1, self.fx.count('plans'))

    # 1b. nil version is resolved once ------------------------------------
    def test_a_reused_key_never_switches_to_the_edited_version(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')          # version=None -> item-v1
        self.db.execute("INSERT INTO library_versions(id,item_id,account,ordinal,kind,payload,"
                        "media_token,captured_at,created_at) VALUES('item-v2','item','account',2,"
                        "'text','{\"text\":\"edited\"}',NULL,110,110)")
        self.db.execute("UPDATE library_items SET current_version_id='item-v2' WHERE id='item'")
        # The retry would now resolve item-v2, which is a different request.
        with self.assertRaises(ValueError):
            self.fx.confirm('confirm-1')
        # Naming the frozen version still replays the original task.
        self.assertEqual(task, self.fx.confirm('confirm-1', version='item-v1'))
        self.assertEqual(1, self.fx.count('library_tasks'))
        self.assertEqual('item-v1', self.fx.frozen(task)['version_id'])

    # 1c. create and re-send are distinct operations ----------------------
    def test_a_key_cannot_cross_between_create_and_resend(self):
        self.fx.item()
        first = self.fx.confirm('confirm-1')
        with self.assertRaises(ValueError):
            self.fx.resend(first, 'confirm-1')
        resent = self.fx.resend(first, 'confirm-2')
        self.assertNotEqual(first, resent)
        self.assertEqual(first, self.fx.frozen(resent)['origin_task_id'])
        self.assertEqual(resent, self.fx.resend(first, 'confirm-2'))
        # Another task cannot borrow this re-send key.
        second = self.fx.confirm('confirm-3')
        with self.assertRaises(ValueError):
            self.fx.resend(second, 'confirm-2')
        # And a re-send key cannot be reused by a create.
        with self.assertRaises(ValueError):
            self.fx.confirm('confirm-2')
        self.assertEqual(3, self.fx.count('library_tasks'))
        # Re-sending changed no target, claim or frozen byte.
        self.assertEqual(0, self.fx.count('source_claims'))
        self.assertEqual(self.fx.frozen(first)['frozen_sha256'],
                         self.fx.frozen(resent)['frozen_sha256'])

    # 2. independent tasks ------------------------------------------------
    def test_same_version_produces_two_independent_tasks(self):
        self.fx.item()
        first = self.fx.confirm('confirm-a')
        second = self.fx.confirm('confirm-b')
        self.assertNotEqual(first, second)
        rows = self.db.execute('SELECT id,plan_id,rule_id,version_id,run_id FROM library_tasks '
                               'ORDER BY id').fetchall()
        self.assertEqual(2, len(rows))
        self.assertEqual(2, len({row[1] for row in rows}))
        self.assertEqual(2, len({row[2] for row in rows}))
        self.assertEqual({'item-v1'}, {row[3] for row in rows})
        self.assertEqual({None}, {row[4] for row in rows})

    # 3. freeze is not the entry -----------------------------------------
    def test_editing_the_entry_never_rewrites_a_frozen_task(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        self.fx.start(task)
        before = self.db.execute(self.fx.by_id, (task, 'account')).fetchone()
        self.db.execute("INSERT INTO library_versions(id,item_id,account,ordinal,kind,payload,media_token,"
                        "captured_at,created_at) VALUES('item-v2','item','account',2,'text',"
                        "'{\"text\":\"edited\"}',NULL,110,110)")
        self.db.execute("UPDATE library_items SET current_version_id='item-v2', updated_at=110 "
                        "WHERE id='item'")
        after = self.db.execute(self.fx.by_id, (task, 'account')).fetchone()
        self.assertEqual(before, after)
        columns = [column[0] for column in self.db.execute('SELECT * FROM library_tasks LIMIT 0').description]
        frozen = dict(zip(columns, after))
        self.assertEqual('item-v1', frozen['version_id'])
        self.assertEqual('hi', json.loads(frozen['frozen_snapshot'])['payload']['text'])
        # The frozen row itself is immutable, even by a direct statement.
        for assignment in ("version_id='item-v2'", "frozen_snapshot='{}'", "confirmation_id='other'",
                           "target_count=1", "run_id='forged'"):
            with self.subTest(assignment=assignment):
                with self.assertRaises(sqlite3.IntegrityError):
                    self.db.execute(f'UPDATE library_tasks SET {assignment} WHERE id=?', (task,))

    # 4. deleting the entry cannot break the task -------------------------
    def test_deleting_an_entry_cannot_destroy_a_frozen_version(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM library_versions WHERE id='item-v1'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM library_items WHERE id='item'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('DELETE FROM library_tasks WHERE id=?', (task,))
        self.assertEqual(1, self.fx.count('library_tasks'))
        # The media of that version is still referenced by all three owners.
        owners = {row[0] for row in self.db.execute(
            'SELECT owner_kind FROM media_references WHERE token=?', (TOKEN,))}
        self.assertEqual({'plan', 'history'}, owners)
        self.assertEqual(1, self.db.execute("SELECT COUNT(*) FROM library_versions WHERE id='item-v1'")
                         .fetchone()[0])

    # 5. mutual exclusion -------------------------------------------------
    def test_group_content_and_library_tasks_are_mutually_exclusive(self):
        self.fx.item()
        self.db.execute("INSERT INTO operations_contents(id,account,source_group,message_id,"
                        "configuration,envelope,captured_at) VALUES('content','account',"
                        "'mother@chatroom','message','{}','{}',100)")
        self.assertEqual(1, len(self.db.execute(self.fx.active_content, ('account',)).fetchall()))
        # The store refuses to freeze while a group capture occupies the account.
        self.assertIn('Handle the current group-sync content before freezing a library task',
                      STORE)
        self.db.execute("UPDATE operations_contents SET archived_at=120 WHERE id='content'")
        self.assertEqual([], self.db.execute(self.fx.active_content, ('account',)).fetchall())
        task = self.fx.confirm('confirm-1')
        run = self.fx.start(task)
        self.assertEqual(1, len(self.db.execute(self.fx.active_run, ('account',)).fetchall()))
        # One active execution per account blocks a second start, whatever its origin.
        self.assertIn('Another run already occupies this account', STORE)
        self.fx.confirm('confirm-2')
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute(self.fx.insert_run, ('run-second', 'rule-account:confirm-2', 'account', 100.0,
                                                 5.0, 10.0, '{}'))
        self.assertEqual('awaiting_resume',
                         self.db.execute('SELECT state FROM runs WHERE id=?', (run,)).fetchone()[0])

    # 6. account isolation ------------------------------------------------
    def test_tasks_and_confirmations_are_account_scoped(self):
        self.fx.item(account='account')
        self.fx.item(account='other', identifier='other-item')
        mine = self.fx.confirm('shared-confirmation', account='account')
        theirs = self.fx.confirm('shared-confirmation', account='other', identifier='other-item')
        self.assertNotEqual(mine, theirs)
        self.assertEqual(2, self.fx.count('library_tasks'))
        self.assertIsNone(self.db.execute(self.fx.by_id, (mine, 'other')).fetchone())
        self.assertIsNone(self.db.execute(self.fx.by_id, (theirs, 'account')).fetchone())
        # Another account's confirmation can never resolve to this account's task.
        self.assertEqual(theirs, self.db.execute(self.fx.by_confirmation,
                                                ('other', 'shared-confirmation')).fetchone()[0])

    # 7. restart ----------------------------------------------------------
    def test_frozen_scope_and_references_survive_a_reopen(self):
        directory = tempfile.mkdtemp()
        path = str(Path(directory) / 'tasks.sqlite3')
        db = sqlite3.connect(path)
        db.execute('PRAGMA foreign_keys=ON')
        schema(db)
        fx = TaskFixture(db)
        fx.item()
        task = fx.confirm('confirm-1')
        fx.start(task)
        expected = db.execute(fx.by_id, (task, 'account')).fetchone()
        db.commit()
        db.close()

        reopened = sqlite3.connect(path)
        reopened.execute('PRAGMA foreign_keys=ON')
        fx2 = TaskFixture(reopened)
        restored = reopened.execute(fx2.by_id, (task, 'account')).fetchone()
        self.assertEqual(expected, restored)
        columns = [column[0] for column in reopened.execute('SELECT * FROM library_tasks LIMIT 0').description]
        frozen = dict(zip(columns, restored))
        self.assertEqual(frozen['frozen_sha256'], digest(frozen['frozen_snapshot']))
        self.assertEqual('message_library', reopened.execute(fx2.source_kind, (frozen['plan_id'],)).fetchone()[0])
        self.assertEqual(task, reopened.execute(fx2.by_run, (frozen['run_id'],)).fetchone()[0])
        targets = [row[0] for row in reopened.execute(fx2.allocations, (frozen['rule_id'],))]
        self.assertEqual(TARGETS, targets)
        self.assertEqual(frozen['target_sha256'], target_digest(targets))
        self.assertEqual(3, reopened.execute("SELECT COUNT(*) FROM media_references WHERE token=?",
                                             (TOKEN,)).fetchone()[0])
        self.assertEqual(3, reopened.execute('SELECT COUNT(*) FROM deliveries WHERE run_id=?',
                                             (frozen['run_id'],)).fetchone()[0])
        reopened.close()

    # 8. legacy callbacks -------------------------------------------------
    def test_legacy_callbacks_cannot_enter_a_frozen_task(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        run = self.fx.start(task)
        self.assertEqual(task, self.db.execute(self.fx.by_run, (run,)).fetchone()[0])
        # Every legacy entry point checks membership before touching the run.
        for guard in ('Message-library continuation is unavailable',
                      'A message-library task is never dispatched by the legacy runner',
                      'A message-library task never accepts a legacy delivery result'):
            with self.subTest(guard=guard):
                self.assertIn(guard, STORE)
        self.assertEqual(1, count('SELECT id,account FROM library_tasks WHERE run_id=?'))
        self.assertEqual(3, STORE.count('[self libraryTaskForRunUnchecked:'))
        # A library plan can never be started or read as a group-sync source.
        self.assertIn('A message-library plan must start through its own frozen task entry', STORE)
        self.assertIn('This plan belongs to the message library and has no group source', STORE)
        self.assertEqual(1, count('SELECT source_kind FROM plan_sources WHERE plan_id=?'))
        # Re-sending never removes a claim or a receipt.
        section = task_section()
        for forbidden in ('DELETE FROM source_claims', 'DELETE FROM native_attempt_claims',
                          'DELETE FROM submission_receipts', 'DELETE FROM library_tasks',
                          'INSERT INTO source_claims', 'claimNextForRun', 'SRRunner'):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, section)

    def test_active_library_run_is_not_projected_as_a_legacy_run(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        self.fx.start(task)
        # The unclaimed-legacy-run projection excludes library-owned runs.
        self.assertIn('library_tasks t WHERE t.run_id=x.id',
                      self.fx.legacy_projection)
        self.assertEqual([], self.db.execute(self.fx.legacy_projection, ('account',)).fetchall())
        # A group-sync run with no content is still visible to that projection.
        self.db.execute("UPDATE runs SET state='ended' WHERE account='account'")
        self.db.execute("INSERT INTO plans VALUES('group-plan','account','mother','[]','[]','{}')")
        self.db.execute("INSERT INTO rules VALUES('group-rule','group-plan','One',1,5,10)")
        self.db.execute(self.fx.insert_run, ('group-run', 'group-rule', 'account', 100.0, 5.0, 10.0, '{}'))
        rows = self.db.execute(self.fx.legacy_projection, ('account',)).fetchall()
        self.assertEqual(['group-run'], [row[0] for row in rows])

    # 3b. one legal transition --------------------------------------------
    def test_a_frozen_row_only_accepts_one_run_attachment(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        other = self.fx.confirm('confirm-2')
        frozen = self.fx.frozen(task)
        other_frozen = self.fx.frozen(other)
        # The single legal transition: run_id and started_at NULL -> value.
        self.db.execute("INSERT INTO runs(id,rule_id,account,state,started_at,minimum,maximum,snapshot) "
                        "VALUES('run-one',?,'account','awaiting_resume',100,5,10,?)",
                        (frozen['rule_id'], frozen['frozen_snapshot']))
        self.db.execute(self.fx.attach_run, ('run-one', 100.0, task, 'account'))
        self.assertEqual('run-one', self.fx.frozen(task)['run_id'])
        for assignment in ("media_token=NULL",
                           "media_token='22222222-2222-3333-4444-555555555555'",
                           "origin_task_id='other'", "created_at=1", "account='other'",
                           "target_count=1", "confirmation_id='other'", "frozen_sha256='x'",
                           "started_at=NULL", "started_at=200"):
            with self.subTest(assignment=assignment):
                with self.assertRaises(sqlite3.IntegrityError) as caught:
                    self.db.execute(f'UPDATE library_tasks SET {assignment} WHERE id=?', (task,))
                self.assertIn('immutable', str(caught.exception))
        # Every other frozen column is refused as well; some also fail a foreign
        # key or uniqueness rule, which is still a refusal, never a rewrite.
        for assignment in ("run_id=NULL", "run_id='run-two'", "version_id='item-v2'",
                           "item_id='other'", f"plan_id='{other_frozen['plan_id']}'",
                           f"rule_id='{other_frozen['rule_id']}'", "target_sha256='x'"):
            with self.subTest(assignment=assignment):
                with self.assertRaises(sqlite3.IntegrityError):
                    self.db.execute(f'UPDATE library_tasks SET {assignment} WHERE id=?', (task,))
        # No-op updates are not a back door once the run is attached.
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('UPDATE library_tasks SET run_id=run_id WHERE id=?', (task,))
        self.assertEqual('run-one', self.fx.frozen(task)['run_id'])

    # 3c. current-schema trigger definitions keep their rows ---------------
    def test_an_older_trigger_definition_is_replaced_without_touching_rows(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        self.db.commit()
        # Simulate an older trigger definition. IF NOT EXISTS would silently
        # keep it forever, while the current schema setup replaces it.
        self.db.execute('DROP TRIGGER library_tasks_frozen')
        self.db.execute("CREATE TRIGGER library_tasks_frozen BEFORE UPDATE ON library_tasks "
                        "WHEN NEW.confirmation_id<>OLD.confirmation_id OR NEW.item_id<>OLD.item_id "
                        "OR NEW.version_id<>OLD.version_id OR NEW.plan_id<>OLD.plan_id "
                        "OR NEW.rule_id<>OLD.rule_id OR NEW.frozen_snapshot<>OLD.frozen_snapshot "
                        "OR NEW.frozen_sha256<>OLD.frozen_sha256 "
                        "OR NEW.target_sha256<>OLD.target_sha256 OR NEW.target_count<>OLD.target_count "
                        "OR (OLD.run_id IS NOT NULL AND NEW.run_id IS NOT OLD.run_id) "
                        "BEGIN SELECT RAISE(ABORT,'A frozen message-library task is immutable'); END")
        self.db.commit()
        # Prove the weaker definition really did allow the null-token rewrite.
        self.db.execute('UPDATE library_tasks SET media_token=NULL WHERE id=?', (task,))
        self.assertIsNone(self.fx.frozen(task)['media_token'])
        frozen = self.fx.frozen(task)
        self.db.execute("INSERT INTO runs(id,rule_id,account,state,started_at,minimum,maximum,snapshot) "
                        "VALUES('run-legacy',?,'account','awaiting_resume',100,5,10,?)",
                        (frozen['rule_id'], frozen['frozen_snapshot']))
        self.db.execute(self.fx.attach_run, ('run-legacy', 100.0, task, 'account'))
        self.db.execute('UPDATE library_tasks SET media_token=? WHERE id=?', (TOKEN, task))
        before = self.db.execute('SELECT * FROM library_tasks ORDER BY id').fetchall()
        self.db.execute('PRAGMA user_version=14')
        self.db.commit()
        reopen_current(self.db)                # production DDL, DROP + CREATE triggers
        self.assertEqual(14, self.db.execute('PRAGMA user_version').fetchone()[0])
        self.assertEqual(before, self.db.execute('SELECT * FROM library_tasks ORDER BY id').fetchall())
        self.assertEqual(1, self.fx.count('library_items'))
        self.assertEqual([], self.db.execute('PRAGMA foreign_key_check').fetchall())
        with self.assertRaises(sqlite3.IntegrityError) as caught:
            self.db.execute('UPDATE library_tasks SET media_token=NULL WHERE id=?', (task,))
        self.assertIn('immutable', str(caught.exception))
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE library_tasks SET origin_task_id='other' WHERE id=?", (task,))

    # 3d. occupancy projection --------------------------------------------
    def test_a_library_run_occupies_only_its_own_account(self):
        self.fx.item()
        self.fx.item(account='other', identifier='other-item')
        task = self.fx.confirm('confirm-1')
        # Frozen but not started: no run, so the account is not occupied yet.
        self.assertEqual([], self.db.execute(self.fx.occupancy, ('account',)).fetchall())
        run = self.fx.start(task)
        self.assertEqual([(task, run, 'awaiting_resume')],
                         [row[:3] for row in self.db.execute(self.fx.occupancy, ('account',))])
        self.assertEqual([], self.db.execute(self.fx.occupancy, ('other',)).fetchall())
        # A paused library run keeps the single execution slot.
        self.db.execute("UPDATE runs SET state='paused' WHERE id=?", (run,))
        self.assertEqual(1, len(self.db.execute(self.fx.occupancy, ('account',)).fetchall()))
        # Cancelling releases the slot; the frozen task keeps its own run id.
        self.db.execute("INSERT INTO operations_cancellations(run_id,requested_at) VALUES(?,120)", (run,))
        self.db.execute("UPDATE runs SET state='ended',ended_at=120 WHERE id=?", (run,))
        self.assertEqual([], self.db.execute(self.fx.occupancy, ('account',)).fetchall())
        self.assertEqual(run, self.fx.frozen(task)['run_id'])

    # structural ----------------------------------------------------------
    def test_frozen_triggers_are_recreated_not_left_at_an_older_definition(self):
        # CREATE TRIGGER IF NOT EXISTS would keep an older definition forever.
        for trigger in ('library_tasks_frozen', 'library_tasks_no_delete',
                        'library_versions_no_update', 'library_versions_no_delete',
                        'plan_sources_library_source'):
            with self.subTest(trigger=trigger):
                self.assertIn(f'DROP TRIGGER IF EXISTS {trigger}', STORE)
                self.assertNotIn(f'CREATE TRIGGER IF NOT EXISTS {trigger}', STORE)
                self.assertEqual(1, STORE.count(f'CREATE TRIGGER {trigger} '))
        # NULL is compared with IS / IS NOT, never with <>.
        frozen = [sql for sql in statements(STORE)
                  if sql.startswith('CREATE TRIGGER library_tasks_frozen ')][0]
        self.assertIn('IS NOT OLD.', frozen)
        self.assertNotIn('<>OLD.', frozen)
        for guard in ('OLD.run_id IS NOT NULL', 'OLD.started_at IS NOT NULL',
                      'NEW.run_id IS NULL', 'NEW.started_at IS NULL',
                      'NEW.origin_task_id IS NOT OLD.origin_task_id',
                      'NEW.media_token IS NOT OLD.media_token',
                      'NEW.created_at IS NOT OLD.created_at',
                      'NEW.account IS NOT OLD.account'):
            self.assertIn(guard, frozen)

    def test_media_token_is_verified_against_the_frozen_payload(self):
        # Read-back compares the column with the payload token using IS semantics,
        # requires the token to be registered for the account, and start() writes
        # the run reference from the payload rather than from the column.
        self.assertIn('SRSameOptionalValue(row[@"media_token"], frozenToken)', STORE)
        self.assertIn('"SELECT token FROM media_assets WHERE token=? AND account=?"', STORE)
        self.assertIn('Library media belongs to no media record of this account', STORE)
        self.assertIn('sealedToken', STORE)
        self.assertNotIn("frozen[@\"mediaToken\"]", STORE)

    def test_read_back_declares_each_local_once(self):
        # A duplicated block re-declared `snapshot` in the same scope, which does
        # not compile. The whole second copy is gone, not renamed.
        readback = STORE.split('- (NSDictionary *)libraryTaskUnchecked:', 1)[1].split('\n}', 1)[0]
        self.assertEqual(1, readback.count('NSDictionary *snapshot ='))
        for check in ('Frozen task snapshot was altered',
                      'Frozen task source identity is inconsistent',
                      'may not carry a group source identity'):
            self.assertEqual(1, readback.count(check), check)
        declared = re.findall(r'\b(?:NSDictionary|NSMutableDictionary|NSString|NSArray|id)\s*\*?\s*(\w+)\s*=',
                              readback)
        self.assertEqual([], sorted({name for name in declared if declared.count(name) > 1}))

    def test_no_property_is_sent_as_a_bare_selector(self):
        # `[self.stopCapture]` has no selector and does not parse; a message send
        # needs the space. A subscript such as `self.path[self.field]` stays legal
        # and is excluded by requiring the bracket not to follow an operand.
        send = re.compile(r'(?<![\w)\]@"])\[\s*self\.[A-Za-z_]\w*\s*\]')
        for path in sorted(ROOT.glob('Core/*.m')) + sorted(ROOT.glob('UI/*.m')):
            found = send.findall(path.read_text(encoding='utf-8'))
            self.assertEqual([], found, path.name)


    def test_a_confirmation_key_is_compared_across_the_whole_request(self):
        replay = STORE.split('- (NSString *)replayLibraryTaskUncheckedAccount:', 1)[1] \
                     .split('\n}', 1)[0]
        for check in ('existing[@"item_id"]', 'existing[@"version_id"]',
                      'existing[@"target_sha256"]', 'existing[@"target_count"]',
                      'existing[@"minimum"]', 'existing[@"maximum"]',
                      'existing[@"origin_task_id"]'):
            self.assertIn(check, replay)
        # A re-send binds its key to the origin task and the operation itself.
        resend = STORE.split('- (NSString *)resendLibraryTask:', 1)[1].split('transaction:YES', 1)[0]
        self.assertIn('origin:task]', resend)
        self.assertIn('origin:task];', resend.replace('\n', ''))
        # A create binds its key to "no origin", so the two can never collide.
        create = STORE.split('- (NSString *)createLibraryTaskForAccount:', 1)[1].split('transaction:YES', 1)[0]
        self.assertIn('origin:nil]', create)

    def test_frozen_snapshot_carries_no_group_identity(self):
        self.fx.item()
        task = self.fx.confirm('confirm-1')
        columns = [column[0] for column in self.db.execute('SELECT * FROM library_tasks LIMIT 0').description]
        frozen = dict(zip(columns, self.db.execute(self.fx.by_id, (task, 'account')).fetchone()))
        snapshot = json.loads(frozen['frozen_snapshot'])
        self.assertEqual('message_library', snapshot['sourceKind'])
        for key in ('group', 'sender', 'messageID'):
            self.assertNotIn(key, snapshot)
        self.assertIs(False, snapshot['generatedByRelay'])
        self.assertEqual('', self.db.execute('SELECT source_group FROM plans WHERE id=?',
                                             (frozen['plan_id'],)).fetchone()[0])
        self.assertEqual(0, self.fx.count('source_claims'))

    def test_plan_sources_rejects_a_forged_group_identity(self):
        self.fx.item()
        self.db.execute("INSERT INTO plans(id,account,source_group,senders,types,snapshot) "
                        "VALUES('forged','account','mother@chatroom','[]','[\"text\"]','{}')")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO plan_sources(plan_id,account,source_kind,library_item_id,"
                            "library_version_id,target_sha256,recorded_at) VALUES('forged','account',"
                            "'message_library','item','item-v1',?,100)", (target_digest(TARGETS),))
        self.db.execute("INSERT INTO plans(id,account,source_group,senders,types,snapshot) "
                        "VALUES('empty','account','','[]','[\"text\"]','{}')")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO plan_sources(plan_id,account,source_kind,library_item_id,"
                            "library_version_id,target_sha256,recorded_at) VALUES('empty','account',"
                            "'message_library',NULL,NULL,?,100)", (target_digest(TARGETS),))

    # schema compatibility -------------------------------------------------
    def test_unsupported_schema_is_not_an_upgrade_input(self):
        self.fx.item()
        self.fx.confirm('confirm-1')
        self.db.execute('PRAGMA user_version=13')
        self.db.commit()
        with self.assertRaises(sqlite3.IntegrityError):
            reopen_current(self.db)
        self.assertEqual(13, self.db.execute('PRAGMA user_version').fetchone()[0])


if __name__ == '__main__':
    unittest.main()
