#import "SRStore.h"
#import "SRPacing.h"
#import "SRConfiguration.h"
#import "SRSourceMessage.h"
#import "SRImageAssetStore.h"
#import "SRMediaAlertState.h"
#import <sqlite3.h>
#include <math.h>

@interface SRStore () {
    sqlite3 *_db;
}
@property(nonatomic) NSInteger schemaVersion;
- (nullable id)protectedMediaTokensError:(NSError **)error;
- (NSString *)mediaAlertPath;
@end

@implementation SRStore

static void SRRequire(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"SRStoreError" reason:message userInfo:nil];
}

// Library image payloads may carry raster metadata only; a group, sender,
// account or server message ID inside one would be a forged source identity.
static NSArray *SRImagePayloadKeys(void) {
    return @[@"mediaReference", @"snapshotSchema", @"scopeSHA256", @"sha256", @"byteCount",
             @"pixelWidth", @"pixelHeight", @"format"];
}

- (NSArray<NSDictionary *> *)query:(NSString *)sql values:(NSArray *)values {
    sqlite3_stmt *statement = NULL;
    SRRequire(sqlite3_prepare_v2(_db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK,
              @"Database prepare failed");
    NSMutableArray *rows = [NSMutableArray array];
    @try {
        for (NSUInteger i = 0; i < values.count; i++) {
            id value = values[i];
            int rc;
            if (value == NSNull.null) rc = sqlite3_bind_null(statement, (int)i + 1);
            else if ([value isKindOfClass:NSNumber.class]) rc = sqlite3_bind_double(statement, (int)i + 1, [value doubleValue]);
            else rc = sqlite3_bind_text(statement, (int)i + 1, [value UTF8String], -1, SQLITE_TRANSIENT);
            SRRequire(rc == SQLITE_OK, @"Database bind failed");
        }
        int rc;
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (int c = 0; c < sqlite3_column_count(statement); c++) {
                NSString *key = @(sqlite3_column_name(statement, c));
                int type = sqlite3_column_type(statement, c);
                if (type == SQLITE_NULL) row[key] = NSNull.null;
                else if (type == SQLITE_INTEGER) row[key] = @(sqlite3_column_int64(statement, c));
                else if (type == SQLITE_FLOAT) row[key] = @(sqlite3_column_double(statement, c));
                else row[key] = @((const char *)sqlite3_column_text(statement, c));
            }
            [rows addObject:row];
        }
        SRRequire(rc == SQLITE_DONE, @"Database operation failed (constraint, lock or storage error)");
    } @finally { sqlite3_finalize(statement); }
    return rows;
}

- (id)perform:(id (^)(void))work transaction:(BOOL)transaction error:(NSError **)error {
    @synchronized (self) {
        BOOL began = NO;
        @try {
            if (transaction) { [self query:@"BEGIN IMMEDIATE" values:@[]]; began = YES; }
            id result = work();
            if (transaction) [self query:@"COMMIT" values:@[]];
            return result;
        } @catch (NSException *exception) {
            if (began) sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Store" code:1
                userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Store operation failed"}];
            return nil;
        }
    }
}

- (void)migrateRuleIntervalConstraint {
    // Called inside the schema transaction with foreign keys disabled. Keep child references named rules.
    [self query:@"CREATE TABLE rules_interval_v8(id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES plans(id), name TEXT NOT NULL, position INTEGER NOT NULL, minimum REAL NOT NULL CHECK(minimum>=3), maximum REAL NOT NULL CHECK(maximum>=minimum), UNIQUE(plan_id,position))" values:@[]];
    [self query:@"INSERT INTO rules_interval_v8 SELECT id,plan_id,name,position,minimum,maximum FROM rules" values:@[]];
    [self query:@"DROP TABLE rules" values:@[]];
    [self query:@"ALTER TABLE rules_interval_v8 RENAME TO rules" values:@[]];
}

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _imageAssets = [[SRImageAssetStore alloc] initWithDirectory:[path stringByAppendingString:@".media"]];
    if (sqlite3_open_v2(path.fileSystemRepresentation, &_db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (error) *error = [NSError errorWithDomain:@"SyncRelay.Store" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Cannot open relay database"}];
        return nil;
    }
    sqlite3_busy_timeout(_db, 5000);
    __block NSInteger version = 0;
    __block BOOL rebuildRules = NO;
    id setup = [self perform:^id{
        [self query:@"PRAGMA foreign_keys=ON" values:@[]];
        [self query:@"PRAGMA journal_mode=WAL" values:@[]];
        [self query:@"PRAGMA synchronous=FULL" values:@[]];
        version = [[self query:@"PRAGMA user_version" values:@[]].firstObject[@"user_version"] integerValue];
        SRRequire(version >= 0 && version <= 14, @"Unsupported database schema; do not downgrade");
        if (version < 8) {
            rebuildRules = [self query:@"SELECT name FROM sqlite_master WHERE type='table' AND name='rules'" values:@[]].count > 0;
            [self query:@"PRAGMA foreign_keys=OFF" values:@[]];
        }
        return @YES;
    } transaction:NO error:error];
    if (!setup) return nil;
    id migrated = [self perform:^id{
        NSArray *schema = @[
            @"CREATE TABLE IF NOT EXISTS operations_preferences(account TEXT PRIMARY KEY, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)))",
            @"CREATE TABLE IF NOT EXISTS plans(id TEXT PRIMARY KEY, account TEXT NOT NULL, source_group TEXT NOT NULL, senders TEXT NOT NULL, types TEXT NOT NULL, snapshot TEXT NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS rules(id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES plans(id), name TEXT NOT NULL, position INTEGER NOT NULL, minimum REAL NOT NULL CHECK(minimum>=3), maximum REAL NOT NULL CHECK(maximum>=minimum), UNIQUE(plan_id,position))",
            @"CREATE TABLE IF NOT EXISTS allocations(plan_id TEXT NOT NULL REFERENCES plans(id), target TEXT NOT NULL, rule_id TEXT NOT NULL REFERENCES rules(id), position INTEGER NOT NULL, PRIMARY KEY(plan_id,target))",
            @"CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, rule_id TEXT NOT NULL REFERENCES rules(id), account TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('running','paused','awaiting_resume','completed','ended')), started_at REAL NOT NULL, ended_at REAL, minimum REAL NOT NULL, maximum REAL NOT NULL, snapshot TEXT NOT NULL)",
            @"CREATE UNIQUE INDEX IF NOT EXISTS one_active_run ON runs(account) WHERE state IN ('running','paused','awaiting_resume')",
            @"CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), target TEXT NOT NULL, position INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','submitting','confirmed','failed','uncertain','cancelled')), attempt_id TEXT, message_id TEXT, reason TEXT, UNIQUE(run_id,target))",
            @"CREATE INDEX IF NOT EXISTS delivery_queue ON deliveries(run_id,state,position)",
            @"CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY, delivery_id TEXT NOT NULL REFERENCES deliveries(id), started_at REAL NOT NULL, ended_at REAL, state TEXT NOT NULL, message_id TEXT, reason TEXT)",
            @"CREATE TABLE IF NOT EXISTS configurations(account TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS source_claims(account TEXT NOT NULL, source_group TEXT NOT NULL, message_id TEXT NOT NULL, plan_id TEXT NOT NULL UNIQUE REFERENCES plans(id), PRIMARY KEY(account,source_group,message_id))",
            @"CREATE INDEX IF NOT EXISTS plans_by_account ON plans(account)",
            @"CREATE INDEX IF NOT EXISTS runs_by_rule ON runs(rule_id)",
            @"CREATE INDEX IF NOT EXISTS allocations_by_rule ON allocations(rule_id)",
            @"CREATE TABLE IF NOT EXISTS text_experiments(account TEXT NOT NULL, source_group TEXT NOT NULL, source_message_id TEXT NOT NULL, target TEXT NOT NULL, claimed_at REAL NOT NULL, PRIMARY KEY(account,source_group,source_message_id))",
            @"CREATE TABLE IF NOT EXISTS image_experiments(account TEXT NOT NULL, source_group TEXT NOT NULL, source_message_id TEXT NOT NULL, target TEXT NOT NULL, claimed_at REAL NOT NULL, PRIMARY KEY(account,source_group,source_message_id))",
            @"CREATE TABLE IF NOT EXISTS submission_receipts(delivery_id TEXT PRIMARY KEY REFERENCES deliveries(id), attempt_id TEXT NOT NULL UNIQUE REFERENCES attempts(id), submitted_at REAL NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS small_group_runs(run_id TEXT PRIMARY KEY REFERENCES runs(id), authorized_at REAL NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS native_attempt_claims(delivery_id TEXT PRIMARY KEY REFERENCES deliveries(id), attempt_id TEXT NOT NULL UNIQUE REFERENCES attempts(id), claimed_at REAL NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS operations_contents(id TEXT PRIMARY KEY, account TEXT NOT NULL, source_group TEXT NOT NULL, message_id TEXT NOT NULL, configuration TEXT NOT NULL, envelope TEXT NOT NULL, captured_at REAL NOT NULL, plan_id TEXT UNIQUE REFERENCES plans(id), archived_at REAL, UNIQUE(account,source_group,message_id))",
            @"CREATE UNIQUE INDEX IF NOT EXISTS one_operations_content ON operations_contents(account) WHERE archived_at IS NULL",
            @"CREATE TABLE IF NOT EXISTS operations_cancellations(run_id TEXT PRIMARY KEY REFERENCES runs(id), requested_at REAL NOT NULL, drained_at REAL)",
            @"CREATE TABLE IF NOT EXISTS operations_legacy_adoptions(content_id TEXT PRIMARY KEY REFERENCES operations_contents(id), run_id TEXT NOT NULL UNIQUE REFERENCES runs(id), adopted_at REAL NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS library_items(id TEXT PRIMARY KEY, account TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('text','image')), created_at REAL NOT NULL, updated_at REAL NOT NULL, current_version_id TEXT NOT NULL)",
            @"CREATE INDEX IF NOT EXISTS library_items_by_account ON library_items(account, created_at, id)",
            @"CREATE TABLE IF NOT EXISTS library_versions(id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES library_items(id), account TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=1), kind TEXT NOT NULL CHECK(kind IN ('text','image')), payload TEXT NOT NULL, media_token TEXT, captured_at REAL NOT NULL, created_at REAL NOT NULL, UNIQUE(item_id,ordinal))",
            @"CREATE INDEX IF NOT EXISTS library_versions_by_item ON library_versions(item_id, ordinal)",
            // Triggers are not upgraded by IF NOT EXISTS: an existing database
            // keeps whatever definition it was created with. Dropping and
            // recreating them inside this migration transaction makes the source
            // authoritative for schema 13 and 14 development databases without
            // rebuilding a table or rewriting a single row.
            @"DROP TRIGGER IF EXISTS library_versions_no_update",
            @"CREATE TRIGGER library_versions_no_update BEFORE UPDATE ON library_versions BEGIN SELECT RAISE(ABORT,'Library versions are immutable'); END",
            @"DROP TRIGGER IF EXISTS library_versions_no_delete",
            @"CREATE TRIGGER library_versions_no_delete BEFORE DELETE ON library_versions BEGIN SELECT RAISE(ABORT,'Library versions are immutable'); END",
            @"CREATE TABLE IF NOT EXISTS media_assets(token TEXT PRIMARY KEY, account TEXT NOT NULL, scope_kind TEXT NOT NULL CHECK(scope_kind IN ('group_source','message_library')), scope_sha256 TEXT NOT NULL, sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count>0), pixel_width INTEGER, pixel_height INTEGER, format TEXT, created_at REAL NOT NULL, UNIQUE(account,scope_sha256,sha256))",
            @"CREATE TABLE IF NOT EXISTS media_references(account TEXT NOT NULL, token TEXT NOT NULL, owner_kind TEXT NOT NULL CHECK(owner_kind IN ('library_item','library_version','plan','run','history')), owner_id TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(owner_kind,owner_id,token))",
            @"CREATE INDEX IF NOT EXISTS media_references_by_token ON media_references(token)",
            @"CREATE TABLE IF NOT EXISTS content_sources(content_id TEXT PRIMARY KEY REFERENCES operations_contents(id), account TEXT NOT NULL, source_kind TEXT NOT NULL CHECK(source_kind IN ('group_sync','message_library')), library_item_id TEXT REFERENCES library_items(id), library_version_id TEXT REFERENCES library_versions(id), recorded_at REAL NOT NULL)",
            @"INSERT OR IGNORE INTO content_sources(content_id,account,source_kind,library_item_id,library_version_id,recorded_at) SELECT id,account,'group_sync',NULL,NULL,captured_at FROM operations_contents",
            @"CREATE TABLE IF NOT EXISTS plan_sources(plan_id TEXT PRIMARY KEY REFERENCES plans(id), account TEXT NOT NULL, source_kind TEXT NOT NULL CHECK(source_kind IN ('group_sync','message_library')), library_item_id TEXT REFERENCES library_items(id), library_version_id TEXT REFERENCES library_versions(id), target_sha256 TEXT NOT NULL, recorded_at REAL NOT NULL, CHECK((source_kind='group_sync' AND library_item_id IS NULL AND library_version_id IS NULL) OR (source_kind='message_library' AND library_item_id IS NOT NULL AND library_version_id IS NOT NULL)))",
            @"CREATE TRIGGER IF NOT EXISTS plan_sources_library_source BEFORE INSERT ON plan_sources WHEN NEW.source_kind='message_library' AND (SELECT source_group FROM plans WHERE id=NEW.plan_id)<>'' BEGIN SELECT RAISE(ABORT,'A message-library plan may not carry a source group'); END",
            @"CREATE TABLE IF NOT EXISTS library_tasks(id TEXT PRIMARY KEY, account TEXT NOT NULL, confirmation_id TEXT NOT NULL, item_id TEXT NOT NULL REFERENCES library_items(id), version_id TEXT NOT NULL REFERENCES library_versions(id), plan_id TEXT NOT NULL UNIQUE REFERENCES plans(id), rule_id TEXT NOT NULL UNIQUE REFERENCES rules(id), run_id TEXT UNIQUE REFERENCES runs(id), frozen_snapshot TEXT NOT NULL, frozen_sha256 TEXT NOT NULL, media_token TEXT, target_sha256 TEXT NOT NULL, target_count INTEGER NOT NULL CHECK(target_count BETWEEN 1 AND 20), origin_task_id TEXT REFERENCES library_tasks(id), created_at REAL NOT NULL, started_at REAL, UNIQUE(account,confirmation_id))",
            @"CREATE INDEX IF NOT EXISTS library_tasks_by_account ON library_tasks(account, created_at)",
            // The only legal update is attaching the task's single run once:
            // run_id and started_at go NULL -> value together. Everything that
            // identifies the freeze (identity, source entry/version, plan, rule,
            // payload digest, media token, target scope, origin, creation time)
            // is immutable. `IS` / `IS NOT` compare NULL correctly, so a NULL
            // origin or media token cannot be overwritten by another value.
            @"DROP TRIGGER IF EXISTS library_tasks_frozen",
            @"CREATE TRIGGER library_tasks_frozen BEFORE UPDATE ON library_tasks WHEN NEW.id IS NOT OLD.id OR NEW.account IS NOT OLD.account OR NEW.confirmation_id IS NOT OLD.confirmation_id OR NEW.item_id IS NOT OLD.item_id OR NEW.version_id IS NOT OLD.version_id OR NEW.plan_id IS NOT OLD.plan_id OR NEW.rule_id IS NOT OLD.rule_id OR NEW.frozen_snapshot IS NOT OLD.frozen_snapshot OR NEW.frozen_sha256 IS NOT OLD.frozen_sha256 OR NEW.media_token IS NOT OLD.media_token OR NEW.target_sha256 IS NOT OLD.target_sha256 OR NEW.target_count IS NOT OLD.target_count OR NEW.origin_task_id IS NOT OLD.origin_task_id OR NEW.created_at IS NOT OLD.created_at OR OLD.run_id IS NOT NULL OR OLD.started_at IS NOT NULL OR NEW.run_id IS NULL OR NEW.started_at IS NULL BEGIN SELECT RAISE(ABORT,'A frozen message-library task is immutable'); END",
            @"DROP TRIGGER IF EXISTS library_tasks_no_delete",
            @"CREATE TRIGGER library_tasks_no_delete BEFORE DELETE ON library_tasks BEGIN SELECT RAISE(ABORT,'A frozen message-library task is immutable'); END",
            @"CREATE TABLE IF NOT EXISTS library_deletions(item_id TEXT PRIMARY KEY REFERENCES library_items(id), account TEXT NOT NULL, deleted_at REAL NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS operations_source_modes(account TEXT PRIMARY KEY, mode TEXT NOT NULL CHECK(mode IN ('group_sync','message_library')), updated_at REAL NOT NULL)"
        ];
        for (NSString *sql in schema) [self query:sql values:@[]];
        if (rebuildRules) [self migrateRuleIntervalConstraint];
        if (version < 14) {
            SRRequire([self query:@"PRAGMA foreign_key_check" values:@[]].count == 0,
                      @"Database migration found broken foreign key references");
            [self query:@"PRAGMA user_version=14" values:@[]];
        }
        return @YES;
    } transaction:YES error:error];
    id enforced = [self perform:^id{
        [self query:@"PRAGMA foreign_keys=ON" values:@[]];
        SRRequire([[self query:@"PRAGMA foreign_keys" values:@[]].firstObject[@"foreign_keys"] boolValue],
                  @"Database foreign key enforcement is unavailable");
        NSDictionary *row = [self query:@"PRAGMA user_version" values:@[]].firstObject;
        SRRequire(row[@"user_version"] != nil && [row[@"user_version"] integerValue] == 14,
                  @"Database schema did not reach the expected version");
        self.schemaVersion = [row[@"user_version"] integerValue];
        return @YES;
    } transaction:NO error:migrated ? error : NULL];
    if (!migrated || !enforced) return nil;
    /* A damaged snapshot is not proof that its files are unreferenced, and an
     * unreadable library reference is not a licence to delete anything. */
    id retained = [self protectedMediaTokensError:error];
    if (!retained) return nil;
    if ([retained isKindOfClass:NSSet.class]) {
        [self.imageAssets pruneUnreferenced:retained];
        // Only interrupted writes are reclaimed here; referenced media and
        // WeChat's own files are never touched.
        [self.imageAssets pruneTemporaryFilesOlderThan:SR_MEDIA_TEMPORARY_GRACE_SECONDS];
    }
    return self;
}

/* Tokens that must survive pruning. NSNull means the stored references could not
 * be verified; nil means the query itself failed. */
- (id)protectedMediaTokensError:(NSError **)error {
    return [self perform:^id{
        NSMutableSet *references = [NSMutableSet set];
        for (NSDictionary *row in [self query:@"SELECT snapshot FROM plans UNION ALL SELECT envelope AS snapshot FROM operations_contents UNION ALL SELECT snapshot FROM runs WHERE state IN ('running','paused','awaiting_resume')" values:@[]]) {
            NSData *data = [row[@"snapshot"] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            // A damaged plan is not proof that its files are unreferenced.
            if (![snapshot isKindOfClass:NSDictionary.class]) return NSNull.null;
            NSDictionary *payload = snapshot[@"payload"];
            if (![snapshot[@"type"] isEqual:@"image"]) continue;
            NSString *token = [payload isKindOfClass:NSDictionary.class] ? payload[@"mediaReference"] : nil;
            NSUUID *uuid = [token isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:token] : nil;
            if (![uuid.UUIDString isEqual:token]) return NSNull.null;
            [references addObject:token];
        }
        // Every registered owner protects its token: library entries and versions,
        // plan/run/history references, and imported-but-not-yet-filed media.
        for (NSDictionary *row in [self query:@"SELECT token FROM media_assets UNION SELECT token FROM media_references" values:@[]]) {
            NSString *token = row[@"token"];
            NSUUID *uuid = [token isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:token] : nil;
            if (![uuid.UUIDString isEqual:token]) return NSNull.null;
            [references addObject:token];
        }
        return [references copy];
    } transaction:NO error:error];
}

- (void)dealloc { if (_db) sqlite3_close(_db); }

- (NSNumber *)operationsEnabledForAccount:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Verified account is required");
        NSDictionary *row = [self query:@"SELECT enabled FROM operations_preferences WHERE account=?" values:@[account]].firstObject;
        return row ? @([row[@"enabled"] boolValue]) : @NO;
    } transaction:NO error:error];
}

- (BOOL)setOperationsEnabled:(BOOL)enabled account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Verified account is required");
        if (enabled) {
            NSDictionary *row = [self query:@"SELECT payload FROM configurations WHERE account=?" values:@[account]].firstObject;
            NSData *data = [row[@"payload"] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            SRRequire([SRConfiguration operationsRequirementsForDraft:config].count == 0,
                      @"Save a complete source and target configuration before enabling operations");
        }
        [self query:@"INSERT OR REPLACE INTO operations_preferences(account,enabled) VALUES(?,?)" values:@[account, @(enabled)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

/* Which content entry a future group send would read from. Defaults to group
 * sync so an existing install behaves exactly as before. */
- (NSString *)sourceModeForAccount:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Verified account is required");
        NSDictionary *row = [self query:@"SELECT mode FROM operations_source_modes WHERE account=?" values:@[account]].firstObject;
        return row[@"mode"] ?: @"group_sync";
    } transaction:NO error:error];
}
/* Never rewrites a frozen plan, task or claim. Refused while the account's one
 * execution slot is occupied or a captured content is still unended, because a
 * switch would change what the current run means without re-freezing it. */
- (BOOL)setSourceMode:(NSString *)mode account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0 && [@[@"group_sync", @"message_library"] containsObject:mode],
                  @"Verified account and a supported source mode are required");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume')"
            values:@[account]].count == 0, @"End or cancel the active run before switching the source");
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE account=? AND archived_at IS NULL"
            values:@[account]].count == 0, @"Archive the current content before switching the source");
        [self query:@"INSERT OR REPLACE INTO operations_source_modes(account,mode,updated_at) VALUES(?,?,?)"
            values:@[account, mode, @(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSString *)json:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    SRRequire(data != nil, @"Invalid source snapshot");
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSString *)saveOperationsContent:(NSDictionary *)envelope configuration:(NSDictionary *)configuration
                            account:(NSString *)account capturedAt:(NSTimeInterval)capturedAt error:(NSError **)error {
    NSDictionary *draft = [SRSourceMessage frozenJSON:configuration], *message = [SRSourceMessage frozenJSON:envelope];
    return [self perform:^id{
        SRRequire(isfinite(capturedAt) && capturedAt > 0 &&
                  [SRConfiguration operationsRequirementsForDraft:draft].count == 0 &&
                  [SRSourceMessage matchesEnvelope:message configuration:draft account:account], @"Invalid prepared operations content");
        NSDictionary *existing = [self query:@"SELECT id,archived_at FROM operations_contents WHERE account=? AND source_group=? AND message_id=?"
            values:@[account, message[@"group"], message[@"messageID"]]].firstObject;
        if (existing) {
            SRRequire(existing[@"archived_at"] == NSNull.null, @"This source was already processed or discarded");
            return existing[@"id"];
        }
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE account=? AND archived_at IS NULL" values:@[account]].count == 0,
                  @"Current content is occupied; new messages are not queued");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count == 0,
                  @"An existing run must be handled before capturing new content");
        SRRequire([self query:@"SELECT plan_id FROM source_claims WHERE account=? AND source_group=? AND message_id=?"
            values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"Source already belongs to a plan");
        for (NSString *table in @[@"text_experiments", @"image_experiments"])
            SRRequire([self query:[NSString stringWithFormat:@"SELECT target FROM %@ WHERE account=? AND source_group=? AND source_message_id=?", table]
                values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"Source already has an experimental attempt");
        if ([message[@"type"] isEqual:@"image"])
            SRRequire([self.imageAssets dataForPayload:message[@"payload"] source:message error:NULL] != nil, @"Image is not ready or has changed");
        NSString *identifier = NSUUID.UUID.UUIDString;
        [self query:@"INSERT INTO operations_contents(id,account,source_group,message_id,configuration,envelope,captured_at) VALUES(?,?,?,?,?,?,?)"
            values:@[identifier, account, message[@"group"], message[@"messageID"], [self json:draft], [self json:message], @(capturedAt)]];
        return identifier;
    } transaction:YES error:error];
}

- (NSDictionary *)operationsContentForAccount:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Verified account is required");
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSString *kind in @[@"current", @"recent"]) {
            // Unique occupancy makes capture order archive order; clocks can roll back.
            NSString *sql = [kind isEqual:@"current"] ?
                @"SELECT * FROM operations_contents WHERE account=? AND archived_at IS NULL" :
                @"SELECT * FROM operations_contents WHERE account=? AND archived_at IS NOT NULL ORDER BY rowid DESC LIMIT 1";
            NSMutableDictionary *row = [[self query:sql values:@[account]].firstObject mutableCopy];
            if (!row) { result[kind] = NSNull.null; continue; }
            for (NSString *key in @[@"configuration", @"envelope"]) {
                NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:[row[key] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
                SRRequire([decoded isKindOfClass:NSDictionary.class], @"Stored operations content is unreadable");
                row[key] = decoded;
            }
            SRRequire([SRSourceMessage matchesEnvelope:row[@"envelope"] configuration:row[@"configuration"] account:account], @"Stored operations content is invalid");
            SRRequire([row[@"source_group"] isEqual:row[@"envelope"][@"group"]] &&
                [row[@"message_id"] isEqual:row[@"envelope"][@"messageID"]], @"Stored content identity is inconsistent");
            NSDictionary *adoption = [self query:@"SELECT run_id,adopted_at FROM operations_legacy_adoptions WHERE content_id=?" values:@[row[@"id"]]].firstObject;
            SRRequire(adoption || (isfinite([row[@"captured_at"] doubleValue]) && [row[@"captured_at"] doubleValue] > 0),
                @"Stored capture time is invalid");
            if (row[@"plan_id"] != NSNull.null) {
                NSDictionary *plan = [self query:@"SELECT account,source_group,snapshot FROM plans WHERE id=?" values:@[row[@"plan_id"]]].firstObject;
                NSDictionary *snapshot = plan ? [NSJSONSerialization JSONObjectWithData:[plan[@"snapshot"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
                SRRequire([plan[@"account"] isEqual:account] && [plan[@"source_group"] isEqual:row[@"source_group"]] &&
                    [snapshot isEqual:row[@"envelope"]], @"Stored content plan belongs to a different source or account");
            }
            row[@"legacyAdoption"] = adoption ?: (id)NSNull.null;
            row[@"captureTimeKnown"] = @(adoption == nil);
            if (adoption) row[@"captured_at"] = NSNull.null;
            result[kind] = row;
        }
        // A frozen library task owns its run; it is not an unclaimed legacy run
        // awaiting adoption, and it must never block capture as one.
        NSDictionary *legacy = [self query:@"SELECT x.*,r.plan_id FROM runs x JOIN rules r ON r.id=x.rule_id WHERE x.account=? AND x.state IN ('running','paused','awaiting_resume') AND NOT EXISTS(SELECT 1 FROM operations_contents c WHERE c.account=x.account AND c.plan_id=r.plan_id AND c.archived_at IS NULL) AND NOT EXISTS(SELECT 1 FROM library_tasks t WHERE t.run_id=x.id) LIMIT 1" values:@[account]].firstObject;
        result[@"unlinkedActiveRun"] = @(legacy != nil);
        result[@"legacyRun"] = legacy ? [self runCard:legacy] : (id)NSNull.null;
        // Excluding library runs from legacyRun must not make the account look
        // idle: its run still occupies the per-account execution slot, so capture
        // would arm and then fail in saveOperationsContent. Project that
        // occupancy explicitly and account-scoped, without pretending it is a
        // legacy run and without exposing it as dispatchable group content.
        NSDictionary *library = [self query:@"SELECT t.id,t.run_id,x.state,t.started_at FROM library_tasks t JOIN runs x ON x.id=t.run_id WHERE t.account=? AND x.state IN ('running','paused','awaiting_resume') ORDER BY t.created_at LIMIT 1" values:@[account]].firstObject;
        result[@"libraryOccupancy"] = library ? @{@"taskID": library[@"id"], @"runID": library[@"run_id"],
            @"state": library[@"state"], @"startedAt": library[@"started_at"]} : (id)NSNull.null;
        return result;
    } transaction:NO error:error];
}

- (NSString *)adoptLegacyOperationsRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && run.length, @"Account and legacy run are required");
        NSDictionary *batch = [self query:@"SELECT x.*,r.plan_id FROM runs x JOIN rules r ON r.id=x.rule_id JOIN small_group_runs s ON s.run_id=x.id WHERE x.id=? AND x.account=?" values:@[run, account]].firstObject;
        SRRequire(batch != nil, @"Legacy run has no authorized source for this account");
        NSDictionary *existing = [self query:@"SELECT c.id,c.archived_at FROM operations_contents c JOIN operations_legacy_adoptions a ON a.content_id=c.id WHERE a.run_id=? AND c.account=?" values:@[run, account]].firstObject;
        if (existing) {
            SRRequire(existing[@"archived_at"] == NSNull.null, @"Legacy content was already archived");
            return existing[@"id"];
        }
        SRRequire([@[@"paused", @"awaiting_resume"] containsObject:batch[@"state"]] &&
            [self query:@"SELECT id FROM deliveries WHERE run_id=? AND state='submitting' LIMIT 1" values:@[run]].count == 0,
            @"Pause and drain or recover the legacy run before adoption");
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE account=? AND archived_at IS NULL" values:@[account]].count == 0,
            @"Handle the occupied content before adopting another source");
        NSDictionary *plan = [self query:@"SELECT * FROM plans WHERE id=? AND account=?" values:@[batch[@"plan_id"], account]].firstObject;
        SRRequire(plan && [plan[@"snapshot"] isEqual:batch[@"snapshot"]], @"Legacy run source differs from its plan");
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:[plan[@"snapshot"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSArray *senders = [NSJSONSerialization JSONObjectWithData:[plan[@"senders"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSArray *types = [NSJSONSerialization JSONObjectWithData:[plan[@"types"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        SRRequire([message isKindOfClass:NSDictionary.class] && [senders isKindOfClass:NSArray.class] && [types isKindOfClass:NSArray.class], @"Legacy source is unreadable; records were retained");
        NSMutableDictionary *draft = [SRConfiguration emptyDraft];
        draft[@"sourceGroup"] = @{@"id": plan[@"source_group"], @"name": plan[@"source_group"]};
        NSMutableArray *members = [NSMutableArray array], *rules = [NSMutableArray array];
        for (id sender in senders) {
            SRRequire([sender isKindOfClass:NSString.class] && [sender length], @"Legacy sender is invalid");
            [members addObject:@{@"id": sender, @"name": sender}];
        }
        draft[@"senders"] = members; draft[@"types"] = types;
        draft[@"minimum"] = batch[@"minimum"]; draft[@"maximum"] = batch[@"maximum"];
        for (NSDictionary *rule in [self query:@"SELECT * FROM rules WHERE plan_id=? ORDER BY position" values:@[plan[@"id"]]]) {
            SRRequire([rule[@"minimum"] isEqual:batch[@"minimum"]] && [rule[@"maximum"] isEqual:batch[@"maximum"]],
                @"Legacy rules have differing intervals; explicit recovery is required");
            NSMutableArray *targets = [NSMutableArray array];
            for (NSDictionary *row in [self query:@"SELECT target FROM allocations WHERE plan_id=? AND rule_id=? ORDER BY position" values:@[plan[@"id"], rule[@"id"]]])
                [targets addObject:@{@"id": row[@"target"], @"name": row[@"target"]}];
            [rules addObject:@{@"id": rule[@"id"], @"name": rule[@"name"], @"targets": targets}];
        }
        draft[@"rules"] = rules;
        SRRequire([SRConfiguration operationsRequirementsForDraft:draft].count == 0 &&
            [SRSourceMessage matchesEnvelope:message configuration:draft account:account], @"Legacy content cannot be verified; records were retained");
        SRRequire([self query:@"SELECT plan_id FROM source_claims WHERE account=? AND source_group=? AND message_id=? AND plan_id=?"
            values:@[account, message[@"group"], message[@"messageID"], plan[@"id"]]].count == 1, @"Legacy source claim is missing or inconsistent");
        NSArray *targets = [self query:@"SELECT target,position FROM deliveries WHERE run_id=? ORDER BY position" values:@[run]];
        NSArray *allocated = [self query:@"SELECT target,position FROM allocations WHERE plan_id=? AND rule_id=? ORDER BY position" values:@[plan[@"id"], batch[@"rule_id"]]];
        SRRequire(targets.count > 0 && targets.count <= 20 && [targets isEqual:allocated], @"Legacy targets differ from the authorized rule");
        NSString *identifier = NSUUID.UUID.UUIDString;
        // Zero is only a storage sentinel for a pre-upgrade unknown capture time.
        [self query:@"INSERT INTO operations_contents(id,account,source_group,message_id,configuration,envelope,captured_at,plan_id) VALUES(?,?,?,?,?,?,0,?)"
            values:@[identifier, account, message[@"group"], message[@"messageID"], [self json:draft], plan[@"snapshot"], plan[@"id"]]];
        [self query:@"INSERT INTO operations_legacy_adoptions(content_id,run_id,adopted_at) VALUES(?,?,?)"
            values:@[identifier, run, @(NSDate.date.timeIntervalSince1970)]];
        return identifier;
    } transaction:YES error:error];
}

- (NSString *)planForOperationsContent:(NSString *)content account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *row = [self query:@"SELECT * FROM operations_contents WHERE id=? AND account=? AND archived_at IS NULL" values:@[content, account]].firstObject;
        SRRequire(row != nil, @"Active content is unavailable for this account");
        if (row[@"plan_id"] != NSNull.null) return row[@"plan_id"];
        NSDictionary *draft = [NSJSONSerialization JSONObjectWithData:[row[@"configuration"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:[row[@"envelope"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSString *plan = [self createPlanUncheckedFromConfiguration:draft envelope:message account:account];
        [self query:@"UPDATE operations_contents SET plan_id=? WHERE id=?" values:@[plan, content]];
        return plan;
    } transaction:YES error:error];
}

- (BOOL)archiveOperationsContent:(NSString *)content account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *row = [self query:@"SELECT plan_id,archived_at FROM operations_contents WHERE id=? AND account=?" values:@[content, account]].firstObject;
        SRRequire(row != nil, @"Content is unavailable for this account");
        if (row[@"archived_at"] != NSNull.null) return @YES;
        SRRequire([self query:@"SELECT x.id FROM runs x JOIN rules r ON r.id=x.rule_id WHERE r.plan_id=? AND (x.state IN ('running','paused','awaiting_resume') OR EXISTS(SELECT 1 FROM deliveries d WHERE d.run_id=x.id AND d.state='submitting')) LIMIT 1"
            values:@[row[@"plan_id"]]].count == 0, @"End or drain the current run before archiving content");
        [self query:@"UPDATE operations_contents SET archived_at=? WHERE id=?" values:@[@(NSDate.date.timeIntervalSince1970), content]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSString *)createPlanForAccount:(NSString *)account sourceGroup:(NSString *)group
                          senders:(NSArray<NSString *> *)senders types:(NSArray<NSString *> *)types
                   sourceSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && group.length && senders.count && types.count && snapshot.count, @"Source configuration is required");
        for (NSString *sender in senders) SRRequire([sender isKindOfClass:NSString.class] && sender.length, @"Invalid sender wxid");
        for (NSString *type in types) SRRequire([@[@"text", @"image"] containsObject:type], @"Unsupported message type");
        NSString *plan = NSUUID.UUID.UUIDString;
        [self query:@"INSERT INTO plans VALUES(?,?,?,?,?,?)"
            values:@[plan, account, group, [self json:senders], [self json:types], [self json:snapshot]]];
        return plan;
    } transaction:YES error:error];
}

- (NSString *)addRuleToPlan:(NSString *)plan name:(NSString *)name targets:(NSArray<NSString *> *)targets
                    minimum:(double)minimum maximum:(double)maximum error:(NSError **)error {
    return [self perform:^id{
        SRPacing pacing = {0};
        SRRequire(SRPacingConfigure(&pacing, minimum, maximum), @"Interval must satisfy 3 <= minimum <= maximum");
        NSDictionary *source = [self query:@"SELECT source_group FROM plans WHERE id=?" values:@[plan]].firstObject;
        SRRequire(source && name.length && targets.count, @"Plan, rule name and targets are required");
        SRRequire([NSSet setWithArray:targets].count == targets.count, @"Duplicate targets");
        NSString *rule = NSUUID.UUID.UUIDString;
        [self query:@"INSERT INTO rules SELECT ?,?,?,COALESCE(MAX(position),0)+1,?,? FROM rules WHERE plan_id=?"
            values:@[rule, plan, name, @(minimum), @(maximum), plan]];
        NSUInteger position = 0;
        for (NSString *target in targets) {
            SRRequire([target isKindOfClass:NSString.class] && target.length && ![target isEqual:source[@"source_group"]], @"Invalid target or source group selected");
            [self query:@"INSERT INTO allocations VALUES(?,?,?,?)" values:@[plan, target, rule, @(position++)]];
        }
        return rule;
    } transaction:YES error:error];
}

- (NSString *)startRule:(NSString *)rule replay:(BOOL)replay error:(NSError **)error {
    return [self perform:^id{ return [self startRuleUnchecked:rule replay:replay]; } transaction:YES error:error];
}
- (NSString *)startRuleUnchecked:(NSString *)rule replay:(BOOL)replay {
        NSDictionary *config = [self query:@"SELECT r.*,p.account,p.snapshot FROM rules r JOIN plans p ON p.id=r.plan_id WHERE r.id=?" values:@[rule]].firstObject;
        SRRequire(config != nil, @"Unknown rule");
        SRRequire([self sourceKindForPlanUnchecked:config[@"plan_id"]] == nil ||
                  [[self sourceKindForPlanUnchecked:config[@"plan_id"]] isEqual:@"group_sync"],
                  @"A message-library plan must start through its own frozen task entry");
        BOOL history = [self query:@"SELECT id FROM runs WHERE rule_id=? LIMIT 1" values:@[rule]].count > 0;
        SRRequire(history == replay, @"Existing history requires explicit replay; new rules require initial start");
        if (!history) {
            NSArray *blocked = [self query:@"SELECT r.id FROM rules r WHERE r.plan_id=? AND r.position<? AND NOT EXISTS(SELECT 1 FROM runs x WHERE x.rule_id=r.id AND x.state IN ('completed','ended')) LIMIT 1"
                values:@[config[@"plan_id"], config[@"position"]]];
            SRRequire(blocked.count == 0, @"Previous rule has not ended");
        }
        NSString *run = NSUUID.UUID.UUIDString;
        [self query:@"INSERT INTO runs(id,rule_id,account,state,started_at,minimum,maximum,snapshot) VALUES(?,?,?,'running',?,?,?,?)"
            values:@[run, rule, config[@"account"], @(NSDate.date.timeIntervalSince1970), config[@"minimum"], config[@"maximum"], config[@"snapshot"]]];
        NSArray *targets = [self query:@"SELECT target,position FROM allocations WHERE rule_id=? ORDER BY position" values:@[rule]];
        SRRequire(targets.count > 0, @"No targets");
        for (NSDictionary *target in targets) [self query:@"INSERT INTO deliveries(id,run_id,target,position,state) VALUES(?,?,?,?,'pending')"
            values:@[NSUUID.UUID.UUIDString, run, target[@"target"], target[@"position"]]];
        return run;
}

- (NSDictionary *)smallGroupSourceForRule:(NSString *)rule account:(NSString *)account {
    NSDictionary *row = [self query:@"SELECT p.*,r.id AS rule_id FROM rules r JOIN plans p ON p.id=r.plan_id WHERE r.id=? AND p.account=?" values:@[rule, account]].firstObject;
    SRRequire(row != nil, @"Rule is unavailable for this account");
    // A library plan has no group source; the group-sync sender must never be
    // handed one, even if a caller invents a group ID.
    SRRequire([self sourceKindForPlanUnchecked:row[@"id"]] == nil ||
              [[self sourceKindForPlanUnchecked:row[@"id"]] isEqual:@"group_sync"],
              @"This plan belongs to the message library and has no group source");
    NSDictionary *source = [NSJSONSerialization JSONObjectWithData:[row[@"snapshot"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSArray *senders = [NSJSONSerialization JSONObjectWithData:[row[@"senders"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSArray *types = [NSJSONSerialization JSONObjectWithData:[row[@"types"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    SRRequire([source isKindOfClass:NSDictionary.class] && [senders isKindOfClass:NSArray.class] && [types isKindOfClass:NSArray.class], @"Source is unreadable");
    for (NSString *key in @[@"account", @"group", @"sender", @"messageID", @"type"])
        SRRequire([source[key] isKindOfClass:NSString.class] && [source[key] length], @"Source identity is incomplete");
    SRRequire([source[@"account"] isEqual:account] && [source[@"group"] isEqual:row[@"source_group"]] &&
        [source[@"generatedByRelay"] isEqual:@NO] && [senders containsObject:source[@"sender"]] &&
        [types containsObject:source[@"type"]] && [@[@"text", @"image"] containsObject:source[@"type"]] &&
        [source[@"payload"] isKindOfClass:NSDictionary.class], @"Source does not match the frozen plan");
    SRRequire([self query:@"SELECT plan_id FROM source_claims WHERE account=? AND source_group=? AND message_id=? AND plan_id=?"
        values:@[account, source[@"group"], source[@"messageID"], row[@"id"]]].count == 1, @"A confirmed capture plan is required");
    for (NSString *table in @[@"text_experiments", @"image_experiments"])
        SRRequire([self query:[NSString stringWithFormat:@"SELECT target FROM %@ WHERE account=? AND source_group=? AND source_message_id=?", table]
            values:@[account, source[@"group"], source[@"messageID"]]].count == 0, @"This source already has a single-target attempt; capture a new message");
    NSArray *targets = [self query:@"SELECT target FROM allocations WHERE rule_id=?" values:@[rule]];
    SRRequire(targets.count > 0 && targets.count <= 20, @"This device checkpoint allows only 1 to 20 target groups per rule");
    for (NSDictionary *target in targets) SRRequire([target[@"target"] hasSuffix:@"@chatroom"] && ![target[@"target"] isEqual:source[@"group"]], @"Source group cannot be a target");
    if ([source[@"type"] isEqual:@"image"])
        SRRequire([self.imageAssets dataForPayload:source[@"payload"] source:source error:NULL] != nil, @"Image snapshot is missing or changed");
    else SRRequire([source[@"payload"][@"text"] isKindOfClass:NSString.class] && [source[@"payload"][@"text"] length], @"Text snapshot is empty");
    return source;
}
- (NSString *)startSmallGroupRule:(NSString *)rule account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && rule.length, @"Account and rule are required");
        [self smallGroupSourceForRule:rule account:account];
        NSString *run = [self startRuleUnchecked:rule replay:NO];
        [self query:@"INSERT INTO small_group_runs VALUES(?,?)" values:@[run, @(NSDate.date.timeIntervalSince1970)]];
        return run;
    } transaction:YES error:error];
}
- (NSDictionary *)smallGroupRulePreview:(NSString *)rule account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *source = [self smallGroupSourceForRule:rule account:account];
        NSDictionary *row = [self query:@"SELECT minimum,maximum FROM rules WHERE id=?" values:@[rule]].firstObject;
        NSArray *targets = [[self query:@"SELECT target FROM allocations WHERE rule_id=? ORDER BY position" values:@[rule]] valueForKey:@"target"];
        return @{@"source": source, @"targets": targets, @"minimum": row[@"minimum"], @"maximum": row[@"maximum"]};
    } transaction:NO error:error];
}
- (NSDictionary *)smallGroupRunUnchecked:(NSString *)run account:(NSString *)account {
    NSMutableDictionary *row = [[self query:@"SELECT x.* FROM runs x JOIN small_group_runs s ON s.run_id=x.id WHERE x.id=? AND x.account=?" values:@[run, account]].firstObject mutableCopy];
    SRRequire(row != nil, @"Run has no small-group authorization for this account");
    NSDictionary *source = [self smallGroupSourceForRule:row[@"rule_id"] account:account];
    SRRequire([row[@"snapshot"] isEqual:[self json:source]], @"Run source differs from the authorized plan");
    NSArray *targets = [self query:@"SELECT target FROM deliveries WHERE run_id=? ORDER BY position" values:@[run]];
    NSArray *allocated = [self query:@"SELECT target FROM allocations WHERE rule_id=? ORDER BY position" values:@[row[@"rule_id"]]];
    SRRequire(targets.count > 0 && targets.count <= 20 && [targets isEqual:allocated], @"Run targets differ from the authorized rule");
    row[@"source"] = source; row[@"targets"] = [targets valueForKey:@"target"];
    row[@"counts"] = [self countsForRun:run];
    return row;
}
- (NSDictionary *)smallGroupRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{ return [self smallGroupRunUnchecked:run account:account]; } transaction:NO error:error];
}
- (BOOL)endSmallGroupRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *row = [self query:@"SELECT x.state FROM runs x JOIN small_group_runs s ON s.run_id=x.id WHERE x.id=? AND x.account=?" values:@[run, account]].firstObject;
        SRRequire(row != nil, @"Run has no small-group authorization for this account");
        if ([@[@"completed", @"ended"] containsObject:row[@"state"]]) return @YES;
        // Ending must remain possible even if the source image is now missing.
        SRRequire([self endRun:run error:NULL], @"Cannot end this small-group run");
        return @YES;
    } transaction:NO error:error] != nil;
}
- (BOOL)claimSmallGroupDelivery:(NSDictionary *)delivery source:(NSDictionary *)source account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *row = [self query:@"SELECT * FROM deliveries WHERE id=? AND run_id=? AND attempt_id=? AND state='submitting'"
            values:@[delivery[@"id"], delivery[@"run_id"], delivery[@"attempt_id"]]].firstObject;
        SRRequire(row && [row[@"target"] isEqual:delivery[@"target"]], @"Delivery is not the current claimed attempt");
        NSDictionary *run = [self smallGroupRunUnchecked:row[@"run_id"] account:account];
        SRRequire([run[@"state"] isEqual:@"running"] && [run[@"source"] isEqual:source], @"Run is paused, ended or has a different source");
        [self query:@"INSERT INTO native_attempt_claims VALUES(?,?,?)" values:@[row[@"id"], row[@"attempt_id"], @(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (BOOL)pauseRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        [self query:@"UPDATE runs SET state='paused' WHERE id=? AND state='running'" values:@[run]];
        SRRequire(sqlite3_changes(self->_db) == 1, @"Run is not running");
        return @YES;
    } transaction:YES error:error] != nil;
}

- (void)finishOperationsCancellationUnchecked:(NSString *)run {
    if ([self query:@"SELECT run_id FROM operations_cancellations WHERE run_id=? AND drained_at IS NULL" values:@[run]].count == 0) return;
    if ([self query:@"SELECT id FROM deliveries WHERE run_id=? AND state='submitting' LIMIT 1" values:@[run]].count) return;
    NSNumber *now = @(NSDate.date.timeIntervalSince1970);
    [self query:@"UPDATE runs SET state='ended',ended_at=? WHERE id=? AND state IN ('running','paused','awaiting_resume')" values:@[now, run]];
    [self query:@"UPDATE operations_cancellations SET drained_at=? WHERE run_id=? AND drained_at IS NULL" values:@[now, run]];
}

- (BOOL)cancelOperationsRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *row = [self query:@"SELECT state FROM runs WHERE id=? AND account=?" values:@[run, account]].firstObject;
        SRRequire(row != nil, @"Run is unavailable for this account");
        if ([self query:@"SELECT run_id FROM operations_cancellations WHERE run_id=?" values:@[run]].count) return @YES;
        SRRequire([@[@"running", @"paused", @"awaiting_resume"] containsObject:row[@"state"]], @"Run is already terminal");
        [self query:@"INSERT INTO operations_cancellations(run_id,requested_at) VALUES(?,?)" values:@[run, @(NSDate.date.timeIntervalSince1970)]];
        [self query:@"UPDATE runs SET state='paused' WHERE id=? AND state='running'" values:@[run]];
        [self query:@"UPDATE deliveries SET state='cancelled',reason='User cancelled remaining targets' WHERE run_id=? AND state='pending'" values:@[run]];
        [self finishOperationsCancellationUnchecked:run];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSDictionary *)operationsCancellationForRun:(NSString *)run account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire([self query:@"SELECT id FROM runs WHERE id=? AND account=?" values:@[run, account]].count == 1, @"Run is unavailable for this account");
        return [self query:@"SELECT requested_at,drained_at FROM operations_cancellations WHERE run_id=?" values:@[run]].firstObject ?: @{};
    } transaction:NO error:error];
}

- (BOOL)resumeRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        // Continuing a frozen library task is not implemented in this build: no
        // library dispatch path has been written or verified, so the entry is
        // refused rather than presented as a run that happens to be paused. This
        // states what is missing, not a proven architectural conclusion.
        SRRequire([self libraryTaskForRunUnchecked:run] == nil,
                  @"Message-library continuation is unavailable; confirm a new task to re-send");
        SRRequire([self query:@"SELECT run_id FROM operations_cancellations WHERE run_id=?" values:@[run]].count == 0,
                  @"Cancelled runs cannot be resumed; an explicit new batch is required");
        SRRequire([self query:@"SELECT id FROM deliveries WHERE run_id=? AND state='submitting' LIMIT 1" values:@[run]].count == 0,
                  @"Wait for the current in-flight attempt before continuing");
        [self query:@"UPDATE runs SET state='running' WHERE id=? AND state IN ('paused','awaiting_resume')" values:@[run]];
        SRRequire(sqlite3_changes(self->_db) == 1, @"Run is not paused");
        return @YES;
    } transaction:YES error:error] != nil;
}

- (BOOL)recoverInterruptedRuns:(NSError **)error {
    return [self perform:^id{
        [self query:@"UPDATE attempts SET state='uncertain',ended_at=?,reason='Process interrupted' WHERE state='submitting'"
            values:@[@(NSDate.date.timeIntervalSince1970)]];
        [self query:@"UPDATE deliveries SET state='uncertain',reason='Process interrupted' WHERE state='submitting'" values:@[]];
        [self query:@"UPDATE runs SET state='awaiting_resume' WHERE state IN ('running','paused')" values:@[]];
        for (NSDictionary *row in [self query:@"SELECT run_id FROM operations_cancellations WHERE drained_at IS NULL" values:@[]])
            [self finishOperationsCancellationUnchecked:row[@"run_id"]];
        [self query:@"UPDATE runs SET state='completed',ended_at=? WHERE state='awaiting_resume' AND EXISTS(SELECT 1 FROM deliveries d WHERE d.run_id=runs.id) AND NOT EXISTS(SELECT 1 FROM deliveries d WHERE d.run_id=runs.id AND d.state IN ('pending','submitting'))"
            values:@[@(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSDictionary *)claimNextForRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        SRRequire([self libraryTaskForRunUnchecked:run] == nil,
                  @"A message-library task is never dispatched by the legacy runner");
        NSDictionary *batch = [self query:@"SELECT state FROM runs WHERE id=?" values:@[run]].firstObject;
        SRRequire([batch[@"state"] isEqual:@"running"], @"Run is not running");
        SRRequire([self query:@"SELECT id FROM deliveries WHERE run_id=? AND state='submitting' LIMIT 1" values:@[run]].count == 0,
                  @"An in-flight delivery must finish before another target");
        NSMutableDictionary *delivery = [[self query:@"SELECT * FROM deliveries WHERE run_id=? AND state='pending' ORDER BY position LIMIT 1" values:@[run]].firstObject mutableCopy];
        if (!delivery) return nil;
        NSString *attempt = NSUUID.UUID.UUIDString;
        [self query:@"INSERT INTO attempts(id,delivery_id,started_at,state) VALUES(?,?,?,'submitting')"
            values:@[attempt, delivery[@"id"], @(NSDate.date.timeIntervalSince1970)]];
        [self query:@"UPDATE deliveries SET state='submitting',attempt_id=? WHERE id=?" values:@[attempt, delivery[@"id"]]];
        delivery[@"attempt_id"] = attempt;
        delivery[@"state"] = @"submitting";
        return delivery;
    } transaction:YES error:error];
}

- (BOOL)recordResultForDelivery:(NSString *)delivery attempt:(NSString *)attempt state:(NSString *)state
                     messageID:(NSString *)messageID reason:(NSString *)reason error:(NSError **)error {
    return [self perform:^id{
        SRRequire([@[@"submitted", @"confirmed", @"failed", @"uncertain"] containsObject:state], @"Invalid outcome");
        SRRequire(![state isEqual:@"confirmed"] || messageID.length, @"Confirmed result requires a correlated message ID");
        NSDictionary *row = [self query:@"SELECT * FROM deliveries WHERE id=? AND attempt_id=?" values:@[delivery, attempt]].firstObject;
        SRRequire(row != nil, @"Unmatched attempt");
        // A legacy result can never enter a frozen library task: no legacy host
        // ever obtains one of its deliveries, so such a callback is stale.
        SRRequire([self libraryTaskForRunUnchecked:row[@"run_id"]] == nil,
                  @"A message-library task never accepts a legacy delivery result");
        BOOL submitted = [state isEqual:@"submitted"];
        BOOL receipt = [self query:@"SELECT delivery_id FROM submission_receipts WHERE delivery_id=? AND attempt_id=?" values:@[delivery, attempt]].count > 0;
        // Dispatch evidence is a separate axis; it never claims actual delivery.
        NSString *storedState = submitted ? @"uncertain" : state;
        if ([row[@"state"] isEqual:@"uncertain"] && [state isEqual:@"uncertain"]) return @YES;
        if (submitted && receipt) return @YES;
        if (![row[@"state"] isEqual:@"submitting"] && ![row[@"state"] isEqual:@"uncertain"]) {
            SRRequire([row[@"state"] isEqual:storedState], @"Conflicting terminal callback");
            SRRequire(![state isEqual:@"confirmed"] || [row[@"message_id"] isEqual:messageID], @"Conflicting confirmation message ID");
            return @YES;
        }
        [self query:@"UPDATE deliveries SET state=?,message_id=?,reason=? WHERE id=?"
            values:@[storedState, messageID ?: (id)NSNull.null, reason ?: (id)NSNull.null, delivery]];
        [self query:@"UPDATE attempts SET state=?,ended_at=?,message_id=?,reason=? WHERE id=?"
            values:@[state, @(NSDate.date.timeIntervalSince1970), messageID ?: (id)NSNull.null, reason ?: (id)NSNull.null, attempt]];
        if (submitted) [self query:@"INSERT INTO submission_receipts VALUES(?,?,?)"
            values:@[delivery, attempt, @(NSDate.date.timeIntervalSince1970)]];
        if ([state isEqual:@"uncertain"] && !receipt)
            [self query:@"UPDATE runs SET state='paused' WHERE id=? AND state='running'" values:@[row[@"run_id"]]];
        NSArray *remaining = [self query:@"SELECT id FROM deliveries WHERE run_id=? AND state IN ('pending','submitting') LIMIT 1" values:@[row[@"run_id"]]];
        [self finishOperationsCancellationUnchecked:row[@"run_id"]];
        if (!remaining.count) [self query:@"UPDATE runs SET state='completed',ended_at=? WHERE id=? AND state IN ('running','paused','awaiting_resume')"
            values:@[@(NSDate.date.timeIntervalSince1970), row[@"run_id"]]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (BOOL)endRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        if ([self query:@"SELECT run_id FROM operations_cancellations WHERE run_id=?" values:@[run]].count) {
            [self finishOperationsCancellationUnchecked:run];
            SRRequire([self query:@"SELECT id FROM deliveries WHERE run_id=? AND state='submitting' LIMIT 1" values:@[run]].count == 0,
                      @"Cancellation is still draining; preserve the in-flight result");
            return @YES;
        }
        [self query:@"UPDATE runs SET state='ended',ended_at=? WHERE id=? AND state IN ('running','paused','awaiting_resume')"
            values:@[@(NSDate.date.timeIntervalSince1970), run]];
        SRRequire(sqlite3_changes(self->_db) == 1, @"Run is already ended or unknown");
        [self query:@"UPDATE deliveries SET state='cancelled' WHERE run_id=? AND state='pending'" values:@[run]];
        [self query:@"UPDATE attempts SET state='uncertain',ended_at=?,reason='Ended while submitting' WHERE delivery_id IN (SELECT id FROM deliveries WHERE run_id=? AND state='submitting')"
            values:@[@(NSDate.date.timeIntervalSince1970), run]];
        [self query:@"UPDATE deliveries SET state='uncertain',reason='Ended while submitting' WHERE run_id=? AND state='submitting'" values:@[run]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSDictionary *)summaryForRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        NSMutableDictionary *summary = [[self query:@"SELECT * FROM runs WHERE id=?" values:@[run]].firstObject mutableCopy];
        SRRequire(summary != nil, @"Unknown run");
        summary[@"counts"] = [self countsForRun:run];
        return summary;
    } transaction:NO error:error];
}

- (NSArray *)countsForRun:(NSString *)run {
    return [self query:@"SELECT CASE WHEN d.state='uncertain' AND v.attempt_id IS NOT NULL THEN 'submitted' ELSE d.state END AS state,COUNT(*) AS count FROM deliveries d LEFT JOIN submission_receipts v ON v.delivery_id=d.id AND v.attempt_id=d.attempt_id WHERE d.run_id=? GROUP BY CASE WHEN d.state='uncertain' AND v.attempt_id IS NOT NULL THEN 'submitted' ELSE d.state END" values:@[run]];
}

- (NSArray<NSString *> *)allocatedTargetsForPlan:(NSString *)plan error:(NSError **)error {
    return [self perform:^id{
        return [[self query:@"SELECT target FROM allocations WHERE plan_id=? ORDER BY target" values:@[plan]] valueForKey:@"target"];
    } transaction:NO error:error];
}

- (NSDictionary *)configurationForAccount:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Account ID required");
        NSDictionary *row = [self query:@"SELECT payload FROM configurations WHERE account=?" values:@[account]].firstObject;
        if (!row) return [SRConfiguration emptyDraft];
        NSDictionary *draft = [NSJSONSerialization JSONObjectWithData:[row[@"payload"] dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:NULL];
        SRRequire([SRConfiguration validateDraft:draft error:NULL], @"Stored configuration is invalid; not overwritten");
        return draft;
    } transaction:NO error:error];
}

- (BOOL)saveConfiguration:(NSDictionary *)configuration account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0 && [SRConfiguration validateDraft:configuration error:NULL], @"Invalid configuration or account");
        [self query:@"INSERT INTO configurations(account,payload,updated_at) VALUES(?,?,?) ON CONFLICT(account) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at"
            values:@[account, [self json:configuration], @(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSString *)createPlanFromConfiguration:(NSDictionary *)configuration envelope:(NSDictionary *)envelope account:(NSString *)account error:(NSError **)error {
    NSDictionary *draft = [SRSourceMessage frozenJSON:configuration];
    NSDictionary *message = [SRSourceMessage frozenJSON:envelope];
    return [self perform:^id{
        return [self createPlanUncheckedFromConfiguration:draft envelope:message account:account];
    } transaction:YES error:error];
}
- (NSString *)createPlanUncheckedFromConfiguration:(NSDictionary *)draft envelope:(NSDictionary *)message account:(NSString *)account {
        SRRequire([SRSourceMessage matchesEnvelope:message configuration:draft account:account] && [draft[@"rules"] count], @"Captured source does not match the configured rule");
        if ([message[@"type"] isEqual:@"image"])
            SRRequire([self.imageAssets dataForPayload:message[@"payload"] source:message error:NULL] != nil, @"Image snapshot is missing or changed; capture it again");
        NSString *plan = NSUUID.UUID.UUIDString;
        [self query:@"INSERT INTO plans VALUES(?,?,?,?,?,?)" values:@[plan, account, message[@"group"],
            [self json:[draft[@"senders"] valueForKey:@"id"]], [self json:draft[@"types"]], [self json:message]]];
        [self query:@"INSERT INTO source_claims VALUES(?,?,?,?)" values:@[account, message[@"group"], message[@"messageID"], plan]];
        NSUInteger position = 0;
        for (NSDictionary *rule in draft[@"rules"]) {
            NSString *ruleID = NSUUID.UUID.UUIDString;
            [self query:@"INSERT INTO rules VALUES(?,?,?,?,?,?)" values:@[ruleID, plan, rule[@"name"], @(++position), draft[@"minimum"], draft[@"maximum"]]];
            NSUInteger targetPosition = 0;
            for (NSDictionary *target in rule[@"targets"]) [self query:@"INSERT INTO allocations VALUES(?,?,?,?)"
                values:@[plan, target[@"id"], ruleID, @(targetPosition++)]];
        }
        return plan;
}
- (NSArray *)rulesForPlan:(NSString *)plan error:(NSError **)error {
    return [self perform:^id{
        return [self query:@"SELECT id,name,position,minimum,maximum FROM rules WHERE plan_id=? ORDER BY position" values:@[plan]];
    } transaction:NO error:error];
}
- (NSArray *)plansForAccount:(NSString *)account limit:(NSUInteger)limit offset:(NSUInteger)offset error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && limit > 0 && limit <= 100 && offset <= NSIntegerMax, @"Invalid account or page range");
        return [self query:@"SELECT p.id,p.source_group,(SELECT COUNT(*) FROM rules r WHERE r.plan_id=p.id) AS ruleCount,(SELECT COUNT(*) FROM allocations a WHERE a.plan_id=p.id) AS targetCount FROM plans p WHERE p.account=? ORDER BY p.rowid DESC LIMIT ? OFFSET ?"
            values:@[account, @(limit), @(offset)]];
    } transaction:NO error:error];
}
- (NSDictionary *)plan:(NSString *)plan account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && plan.length, @"Account and plan are required");
        NSMutableDictionary *row = [[self query:@"SELECT * FROM plans WHERE id=? AND account=?" values:@[plan, account]].firstObject mutableCopy];
        SRRequire(row != nil, @"Plan is unavailable for this account");
        for (NSString *key in @[@"senders", @"types", @"snapshot"]) {
            id value = [NSJSONSerialization JSONObjectWithData:[row[key] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            SRRequire(value != nil, @"Stored plan content is unreadable"); row[key] = value;
        }
        SRRequire([row[@"senders"] isKindOfClass:NSArray.class] && [row[@"types"] isKindOfClass:NSArray.class] &&
            [row[@"snapshot"] isKindOfClass:NSDictionary.class], @"Stored plan content has an invalid shape");
        return row;
    } transaction:NO error:error];
}
- (NSDictionary *)runCard:(NSDictionary *)row {
    NSMutableDictionary *card = [row mutableCopy];
    [card removeObjectForKey:@"snapshot"]; [card removeObjectForKey:@"account"];
    NSMutableDictionary *counts = [@{@"pending": @0, @"submitting": @0, @"submitted": @0, @"confirmed": @0, @"failed": @0, @"uncertain": @0, @"cancelled": @0} mutableCopy];
    for (NSDictionary *count in [self countsForRun:row[@"id"]])
        counts[count[@"state"]] = count[@"count"];
    card[@"counts"] = counts;
    return card;
}
- (NSArray *)ruleCardsForPlan:(NSString *)plan account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && plan.length && [self query:@"SELECT id FROM plans WHERE id=? AND account=?" values:@[plan, account]].count,
            @"Plan is unavailable for this account");
        NSArray *rules = [self query:@"SELECT r.*,(SELECT COUNT(*) FROM allocations a WHERE a.rule_id=r.id) AS targetCount FROM rules r WHERE r.plan_id=? ORDER BY r.position" values:@[plan]];
        BOOL occupied = [self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count > 0;
        NSMutableArray *cards = [NSMutableArray array]; BOOL precedingEnded = YES;
        for (NSDictionary *rule in rules) {
            NSMutableDictionary *card = [rule mutableCopy];
            NSDictionary *latest = [self query:@"SELECT rowid AS creationOrder,id,rule_id,state,started_at,ended_at,minimum,maximum FROM runs WHERE rule_id=? ORDER BY rowid DESC LIMIT 1" values:@[rule[@"id"]]].firstObject;
            card[@"latestRun"] = latest ? [self runCard:latest] : (id)NSNull.null;
            card[@"accountOccupied"] = @(occupied);
            // An unlock is only a display hint. startRule still rechecks in its transaction.
            card[@"initialUnlocked"] = @(precedingEnded && !latest);
            BOOL endedOnce = [self query:@"SELECT id FROM runs WHERE rule_id=? AND state IN ('completed','ended') LIMIT 1" values:@[rule[@"id"]]].count > 0;
            precedingEnded = precedingEnded && endedOnce;
            [cards addObject:card];
        }
        return cards;
    } transaction:NO error:error];
}
- (NSArray *)historyForRule:(NSString *)rule account:(NSString *)account limit:(NSUInteger)limit offset:(NSUInteger)offset error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && rule.length && limit > 0 && limit <= 100 && offset <= NSIntegerMax, @"Invalid account or page range");
        SRRequire([self query:@"SELECT r.id FROM rules r JOIN plans p ON p.id=r.plan_id WHERE r.id=? AND p.account=?" values:@[rule, account]].count,
            @"Rule is unavailable for this account");
        NSMutableArray *cards = [NSMutableArray array];
        for (NSDictionary *row in [self query:@"SELECT rowid AS creationOrder,id,rule_id,state,started_at,ended_at,minimum,maximum FROM runs WHERE rule_id=? ORDER BY rowid DESC LIMIT ? OFFSET ?" values:@[rule, @(limit), @(offset)]])
            [cards addObject:[self runCard:row]];
        return cards;
    } transaction:NO error:error];
}
- (NSArray *)exceptionsForRun:(NSString *)run account:(NSString *)account limit:(NSUInteger)limit offset:(NSUInteger)offset error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && run.length && limit > 0 && limit <= 100 && offset <= NSIntegerMax, @"Invalid account or page range");
        SRRequire([self query:@"SELECT id FROM runs WHERE id=? AND account=?" values:@[run, account]].count,
            @"Run is unavailable for this account");
        return [self query:@"SELECT d.id,d.target,d.position,d.state,d.reason,d.attempt_id,d.message_id FROM deliveries d LEFT JOIN submission_receipts v ON v.delivery_id=d.id AND v.attempt_id=d.attempt_id WHERE d.run_id=? AND (d.state IN ('failed','cancelled') OR (d.state='uncertain' AND v.attempt_id IS NULL)) ORDER BY d.position LIMIT ? OFFSET ?"
            values:@[run, @(limit), @(offset)]];
    } transaction:NO error:error];
}
- (BOOL)claimTextExperiment:(NSDictionary *)source configuration:(NSDictionary *)configuration
                   account:(NSString *)account target:(NSString *)target error:(NSError **)error {
    NSDictionary *message = [SRSourceMessage frozenJSON:source], *draft = [SRSourceMessage frozenJSON:configuration];
    return [self perform:^id{
        SRRequire([SRSourceMessage matchesEnvelope:message configuration:draft account:account] && [message[@"type"] isEqual:@"text"], @"Invalid experimental text source");
        BOOL allocated = NO;
        for (NSDictionary *rule in draft[@"rules"]) for (NSDictionary *row in rule[@"targets"]) if ([row[@"id"] isEqual:target]) allocated = YES;
        SRRequire(allocated && ![target isEqual:message[@"group"]] && ![[draft[@"excludedGroups"] valueForKey:@"id"] containsObject:target], @"Experimental target is not in the frozen allowed rules");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count == 0, @"An active run already owns this account");
        SRRequire([self query:@"SELECT plan_id FROM source_claims WHERE account=? AND source_group=? AND message_id=?" values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"Source already belongs to a confirmed plan");
        SRRequire([self query:@"SELECT target FROM text_experiments WHERE account=? AND source_group=? AND source_message_id=?" values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"This source already has an experimental attempt; do not resend an unknown outcome");
        SRRequire([self query:@"SELECT target FROM image_experiments WHERE account=? AND source_group=? AND source_message_id=?" values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"This source already has an image attempt; do not resend an unknown outcome");
        [self query:@"INSERT INTO text_experiments VALUES(?,?,?,?,?)" values:@[account, message[@"group"], message[@"messageID"], target, @(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}
- (NSDictionary *)textExperimentSummaryForAccount:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Account ID required");
        NSArray *rows = [self query:@"SELECT claimed_at FROM text_experiments WHERE account=? ORDER BY rowid DESC LIMIT 1" values:@[account]];
        return @{@"claimed": @(rows.count > 0), @"lastClaimedAt": rows.firstObject[@"claimed_at"] ?: @0,
            @"deliveryOutcome": rows.count ? @"uncertain" : @"not_submitted", @"automaticRetry": @NO};
    } transaction:NO error:error];
}
- (BOOL)claimImageExperiment:(NSDictionary *)source configuration:(NSDictionary *)configuration
                    account:(NSString *)account target:(NSString *)target error:(NSError **)error {
    NSDictionary *message = [SRSourceMessage frozenJSON:source], *draft = [SRSourceMessage frozenJSON:configuration];
    return [self perform:^id{
        SRRequire([SRSourceMessage matchesEnvelope:message configuration:draft account:account] && [message[@"type"] isEqual:@"image"], @"Invalid experimental image source");
        BOOL allocated = NO;
        for (NSDictionary *rule in draft[@"rules"]) for (NSDictionary *row in rule[@"targets"]) if ([row[@"id"] isEqual:target]) allocated = YES;
        SRRequire(allocated && ![target isEqual:message[@"group"]] && ![[draft[@"excludedGroups"] valueForKey:@"id"] containsObject:target], @"Experimental target is not in the frozen allowed rules");
        SRRequire([self.imageAssets dataForPayload:message[@"payload"] source:message error:NULL] != nil, @"Image snapshot is missing or changed");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count == 0, @"An active run already owns this account");
        SRRequire([self query:@"SELECT plan_id FROM source_claims WHERE account=? AND source_group=? AND message_id=?" values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"Source already belongs to a confirmed plan");
        for (NSString *table in @[@"text_experiments", @"image_experiments"])
            SRRequire([self query:[NSString stringWithFormat:@"SELECT target FROM %@ WHERE account=? AND source_group=? AND source_message_id=?", table] values:@[account, message[@"group"], message[@"messageID"]]].count == 0, @"This source already has an experimental attempt; do not resend an unknown outcome");
        [self query:@"INSERT INTO image_experiments VALUES(?,?,?,?,?)" values:@[account, message[@"group"], message[@"messageID"], target, @(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}
- (NSDictionary *)imageExperimentSummaryForAccount:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0, @"Account ID required");
        NSArray *rows = [self query:@"SELECT claimed_at FROM image_experiments WHERE account=? ORDER BY rowid DESC LIMIT 1" values:@[account]];
        return @{@"claimed": @(rows.count > 0), @"lastClaimedAt": rows.firstObject[@"claimed_at"] ?: @0,
            @"deliveryOutcome": rows.count ? @"uncertain" : @"not_submitted", @"automaticRetry": @NO};
    } transaction:NO error:error];
}

// Message library: durable entries with stable IDs and immutable versions. The
// only writers here are the library tables; no plan, run, delivery, claim or
// sending call is reachable from this section.
- (NSString *)libraryTokenForPayload:(NSDictionary *)payload kind:(NSString *)kind account:(NSString *)account {
    SRRequire([payload isKindOfClass:NSDictionary.class], @"Library payload must be a dictionary");
    if ([kind isEqual:@"text"]) {
        // A library body may not smuggle a group, account or server message ID.
        SRRequire([[NSSet setWithArray:payload.allKeys] isEqualToSet:[NSSet setWithObject:@"text"]] &&
            [payload[@"text"] isKindOfClass:NSString.class] && [payload[@"text"] length],
            @"Library text must contain only a non-empty text body");
        return nil;
    }
    NSString *scope = [SRImageAssetStore libraryScopeForAccount:account];
    SRRequire(scope && [SRImageAssetStore validPayload:payload] &&
        [[NSSet setWithArray:payload.allKeys] isSubsetOfSet:[NSSet setWithArray:SRImagePayloadKeys()]] &&
        [payload[@"scopeSHA256"] isEqual:scope], @"Library image payload is invalid or scoped to another owner");
    SRRequire([self.imageAssets dataForPayload:payload scopeSHA256:scope error:NULL] != nil,
        @"Library image snapshot is missing or changed; store it again");
    return payload[@"mediaReference"];
}
- (void)recordLibraryReferences:(NSString *)token item:(NSString *)item version:(NSString *)version
                        account:(NSString *)account at:(NSNumber *)now {
    if (!token.length) return;
    [self query:@"INSERT OR IGNORE INTO media_references(account,token,owner_kind,owner_id,created_at) VALUES(?,?,'library_item',?,?)"
        values:@[account, token, item, now]];
    [self query:@"INSERT OR IGNORE INTO media_references(account,token,owner_kind,owner_id,created_at) VALUES(?,?,'library_version',?,?)"
        values:@[account, token, version, now]];
}
- (NSDictionary *)libraryPayloadFromRow:(NSDictionary *)row {
    NSDictionary *payload = @{@"mediaReference": row[@"token"], @"snapshotSchema": @1,
        @"scopeSHA256": row[@"scope_sha256"], @"sha256": row[@"sha256"], @"byteCount": row[@"byte_count"],
        @"pixelWidth": row[@"pixel_width"], @"pixelHeight": row[@"pixel_height"], @"format": row[@"format"]};
    return [SRImageAssetStore validPayload:payload] ? payload : nil;
}
- (NSDictionary *)saveLibraryImageData:(NSData *)data account:(NSString *)account error:(NSError **)error {
    // Two different failures meet here and neither may be captured by the block:
    // the asset store's error and the database error perform: reports, including
    // a COMMIT that fails after the statements themselves succeeded. Both stay in
    // locals until the outcome is decided at the end of this method.
    __block NSError *assetError = nil;
    __block NSDictionary *created = nil; // only bytes this call wrote, never a reused token
    NSError *storeError = nil;
    NSDictionary *payload = [self perform:^id{
        SRRequire(account.length > 0, @"Verified account is required");
        NSString *scope = [SRImageAssetStore libraryScopeForAccount:account];
        NSString *digest = [SRImageAssetStore sha256ForData:data];
        SRRequire(scope && digest, @"Library image data is not a supported raster snapshot");
        NSDictionary *existing = [self query:@"SELECT token,scope_sha256,sha256,byte_count,pixel_width,pixel_height,format FROM media_assets WHERE account=? AND scope_kind='message_library' AND scope_sha256=? AND sha256=?"
            values:@[account, scope, digest]].firstObject;
        if (existing) {
            NSDictionary *reused = [self libraryPayloadFromRow:existing];
            // A reuse owns no new file, so nothing here may ever be discarded.
            if (reused && [self.imageAssets dataForPayload:reused scopeSHA256:scope error:NULL]) return reused;
            // The bytes on disk are authoritative; a vanished file cannot keep a
            // token alive. The stale row stays until the replacement bytes land:
            // no database change is made before the material write succeeds.
        }
        NSError *materialError = nil;
        NSDictionary *fresh = [self.imageAssets saveData:data scopeSHA256:scope error:&materialError];
        // Returning nil below commits an empty transaction, not a rolled-back
        // one. Nothing has been written to the database at this point, so there
        // is no partial row to keep or undo; only the media write failed.
        if (!fresh) { assetError = materialError; return nil; }
        // Recorded before the row write so a failed COMMIT still finds this file.
        created = fresh;
        @try {
            // UNIQUE(account,scope_sha256,sha256) means the unusable row has to
            // go before the replacement can be inserted, both inside this one
            // transaction so a failed insert restores it on rollback.
            if (existing) [self query:@"DELETE FROM media_assets WHERE token=? AND account=?"
                values:@[existing[@"token"], account]];
            [self query:@"INSERT INTO media_assets(token,account,scope_kind,scope_sha256,sha256,byte_count,pixel_width,pixel_height,format,created_at) VALUES(?,?,'message_library',?,?,?,?,?,?,?)"
                values:@[fresh[@"mediaReference"], account, scope, fresh[@"sha256"], fresh[@"byteCount"],
                    fresh[@"pixelWidth"], fresh[@"pixelHeight"], fresh[@"format"], @(NSDate.date.timeIntervalSince1970)]];
        } @catch (NSException *exception) {
            (void)exception;
            // No cleanup here: the bytes are discarded once, below, so a rollback
            // and a failed COMMIT cannot both race into the same deletion.
            @throw;
        }
        return fresh;
    } transaction:YES error:&storeError];
    if (payload) return payload;
    // Precedence: a database failure outranks a refused write. It covers both a
    // rolled-back statement and a COMMIT that never landed, and it is the only
    // failure that leaves bytes on disk without a durable row.
    if (created) [self.imageAssets discardPayload:created];
    if (storeError && error) *error = storeError;
    else if (assetError && error) *error = assetError;
    return nil;
}
- (NSString *)createLibraryItemForAccount:(NSString *)account kind:(NSString *)kind
                                  payload:(NSDictionary *)payload
                               capturedAt:(NSTimeInterval)capturedAt error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length > 0 && [@[@"text", @"image"] containsObject:kind],
            @"Verified account and a supported library kind are required");
        SRRequire(isfinite(capturedAt) && capturedAt > 0, @"Original capture time is required for a library entry");
        NSString *token = [self libraryTokenForPayload:payload kind:kind account:account];
        NSString *item = NSUUID.UUID.UUIDString, *version = NSUUID.UUID.UUIDString;
        NSNumber *now = @(NSDate.date.timeIntervalSince1970);
        [self query:@"INSERT INTO library_items(id,account,kind,created_at,updated_at,current_version_id) VALUES(?,?,?,?,?,?)"
            values:@[item, account, kind, @(capturedAt), now, version]];
        [self query:@"INSERT INTO library_versions(id,item_id,account,ordinal,kind,payload,media_token,captured_at,created_at) VALUES(?,?,?,1,?,?,?,?,?)"
            values:@[version, item, account, kind, [self json:payload], token ?: (id)NSNull.null, @(capturedAt), now]];
        [self recordLibraryReferences:token item:item version:version account:account at:now];
        return item;
    } transaction:YES error:error];
}
- (NSString *)appendLibraryVersion:(NSString *)item account:(NSString *)account
                           payload:(NSDictionary *)payload expectedVersion:(nullable NSString *)expectedVersion
                        capturedAt:(NSTimeInterval)capturedAt error:(NSError **)error {
    return [self perform:^id{
        SRRequire(item.length && account.length, @"Account and library entry are required");
        NSDictionary *row = [self query:@"SELECT kind,current_version_id FROM library_items WHERE id=? AND account=? AND NOT EXISTS(SELECT 1 FROM library_deletions d WHERE d.item_id=library_items.id)"
            values:@[item, account]].firstObject;
        SRRequire(row != nil, @"Library entry is unavailable for this account");
        if (expectedVersion.length)
            SRRequire([row[@"current_version_id"] isEqual:expectedVersion],
                @"Library entry changed since it was displayed; reload before editing");
        SRRequire(isfinite(capturedAt) && capturedAt > 0, @"Original capture time is required for a library version");
        NSString *token = [self libraryTokenForPayload:payload kind:row[@"kind"] account:account];
        NSNumber *ordinal = [self query:@"SELECT COALESCE(MAX(ordinal),0)+1 AS nextOrdinal FROM library_versions WHERE item_id=?"
            values:@[item]].firstObject[@"nextOrdinal"];
        NSString *version = NSUUID.UUID.UUIDString;
        NSNumber *now = @(NSDate.date.timeIntervalSince1970);
        [self query:@"INSERT INTO library_versions(id,item_id,account,ordinal,kind,payload,media_token,captured_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)"
            values:@[version, item, account, ordinal, row[@"kind"], [self json:payload],
                token ?: (id)NSNull.null, @(capturedAt), now]];
        [self query:@"UPDATE library_items SET current_version_id=?,updated_at=? WHERE id=? AND account=?"
            values:@[version, now, item, account]];
        [self recordLibraryReferences:token item:item version:version account:account at:now];
        return version;
    } transaction:YES error:error];
}
- (NSArray *)libraryItemsForAccount:(NSString *)account limit:(NSUInteger)limit offset:(NSUInteger)offset error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && limit > 0 && limit <= 100 && offset <= NSIntegerMax, @"Invalid account or page range");
        return [self query:@"SELECT i.id,i.kind,i.created_at,i.updated_at,i.current_version_id,(SELECT COUNT(*) FROM library_versions v WHERE v.item_id=i.id) AS versionCount FROM library_items i WHERE i.account=? AND NOT EXISTS(SELECT 1 FROM library_deletions d WHERE d.item_id=i.id) ORDER BY i.rowid DESC LIMIT ? OFFSET ?"
            values:@[account, @(limit), @(offset)]];
    } transaction:NO error:error];
}
- (NSDictionary *)libraryItem:(NSString *)item account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(item.length && account.length, @"Account and library entry are required");
        NSMutableDictionary *row = [[self query:@"SELECT id,kind,created_at,updated_at,current_version_id FROM library_items WHERE id=? AND account=? AND NOT EXISTS(SELECT 1 FROM library_deletions d WHERE d.item_id=library_items.id)"
            values:@[item, account]].firstObject mutableCopy];
        SRRequire(row != nil, @"Library entry is unavailable for this account");
        NSMutableArray *versions = [NSMutableArray array];
        for (NSDictionary *stored in [self query:@"SELECT id,ordinal,kind,payload,media_token,captured_at,created_at FROM library_versions WHERE item_id=? AND account=? ORDER BY ordinal"
            values:@[item, account]]) {
            NSData *data = [stored[@"payload"] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *body = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            SRRequire([body isKindOfClass:NSDictionary.class], @"Stored library version is unreadable");
            NSMutableDictionary *version = [stored mutableCopy];
            version[@"payload"] = body;
            [versions addObject:version];
        }
        row[@"versions"] = versions;
        return row;
    } transaction:NO error:error];
}
- (NSDictionary *)sourceForOperationsContent:(NSString *)content account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(content.length && account.length, @"Account and content are required");
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE id=? AND account=?" values:@[content, account]].count == 1,
            @"Content is unavailable for this account");
        NSDictionary *row = [self query:@"SELECT source_kind,library_item_id,library_version_id FROM content_sources WHERE content_id=? AND account=?"
            values:@[content, account]].firstObject;
        // Group sync is the only producer of operations content today; a library
        // origin must be recorded explicitly before it can be served as one.
        return row ?: @{@"source_kind": @"group_sync", @"library_item_id": NSNull.null, @"library_version_id": NSNull.null};
    } transaction:NO error:error];
}

/* Hides an entry from the library list and nothing else. Immutable versions,
 * frozen tasks, plans, claims, deliveries and media bytes all stay, so a task
 * that already froze this entry keeps working and no byte is silently released.
 * Repeated deletion is a no-op that still reports success. */
- (BOOL)deleteLibraryEntry:(NSString *)item account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        SRRequire(item.length && account.length, @"Account and library entry are required");
        SRRequire([self query:@"SELECT id FROM library_items WHERE id=? AND account=?" values:@[item, account]].count == 1,
                  @"Library entry is unavailable for this account");
        [self query:@"INSERT OR IGNORE INTO library_deletions(item_id,account,deleted_at) VALUES(?,?,?)"
            values:@[item, account, @(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

// Message-library tasks: one explicit confirmation freezes a library version,
// its media reference and its target scope into an independent identity that
// shares plans/rules/allocations/runs/deliveries with group sync. No source
// claim is created, rewritten or deleted here, and a frozen snapshot may never
// carry a group, sender or server message ID: a library origin must not be able
// to look like a group source to the legacy validators.
static NSString *SRTargetDigest(NSArray<NSString *> *targets) {
    NSString *canonical = [targets componentsJoinedByString:@"\n"];
    return [SRImageAssetStore sha256ForData:[canonical dataUsingEncoding:NSUTF8StringEncoding]];
}

static BOOL SRDigestMatches(NSString *text, NSString *expected) {
    if (![text isKindOfClass:NSString.class] || ![expected isKindOfClass:NSString.class]) return NO;
    return [[SRImageAssetStore sha256ForData:[text dataUsingEncoding:NSUTF8StringEncoding]] isEqual:expected];
}

/* nil and NSNull both mean "no value"; a query returns NSNull for a NULL column
 * while an absent argument is nil. Never compare those with -isEqual: directly. */
static BOOL SRSameOptionalValue(id left, id right) {
    id a = left ?: NSNull.null, b = right ?: NSNull.null;
    return [a isEqual:b];
}

/* A run may belong to at most one frozen task. nil means "not a library run". */
- (NSDictionary *)libraryTaskForRunUnchecked:(NSString *)run {
    return [self query:@"SELECT id,account FROM library_tasks WHERE run_id=?" values:@[run]].firstObject;
}

- (NSString *)sourceKindForPlanUnchecked:(NSString *)plan {
    NSDictionary *row = [self query:@"SELECT source_kind FROM plan_sources WHERE plan_id=?" values:@[plan]].firstObject;
    return row[@"source_kind"];
}

/* Writes the frozen plan, its target scope and the task row. Never writes a
 * run, delivery, attempt or native claim; starting is a separate command. */
- (NSString *)createLibraryTaskUncheckedAccount:(NSString *)account item:(NSString *)item
                                        version:(NSString *)version snapshot:(NSDictionary *)snapshot
                                        targets:(NSArray<NSString *> *)targets minimum:(double)minimum
                                        maximum:(double)maximum confirmation:(NSString *)confirmation
                                         origin:(NSString *)origin {
    SRPacing pacing = {0};
    SRRequire(SRPacingConfigure(&pacing, minimum, maximum), @"Interval must satisfy 3 <= minimum <= maximum");
    SRRequire([targets isKindOfClass:NSArray.class] && targets.count > 0 && targets.count <= 20,
              @"A frozen task needs 1 to 20 target groups");
    SRRequire([NSSet setWithArray:targets].count == targets.count, @"Duplicate targets");
    for (NSString *target in targets)
        SRRequire([target isKindOfClass:NSString.class] && [target hasSuffix:@"@chatroom"], @"Invalid target group");
    NSString *frozen = [self json:snapshot];
    NSString *digest = [SRImageAssetStore sha256ForData:[frozen dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *targetDigest = SRTargetDigest(targets);
    SRRequire(frozen.length && digest.length && targetDigest.length, @"Frozen task cannot be serialized or verified");
    id payload = snapshot[@"payload"], token = [payload isKindOfClass:NSDictionary.class] ? payload[@"mediaReference"] : nil;
    NSNumber *now = @(NSDate.date.timeIntervalSince1970);
    NSString *plan = NSUUID.UUID.UUIDString, *rule = NSUUID.UUID.UUIDString, *task = NSUUID.UUID.UUIDString;
    // An empty source group is the explicit absence of a group origin; the
    // trigger on plan_sources rejects any library plan that carries one.
    [self query:@"INSERT INTO plans(id,account,source_group,senders,types,snapshot) VALUES(?,?,'','[]',?,?)"
        values:@[plan, account, [self json:@[snapshot[@"type"]]], frozen]];
    [self query:@"INSERT INTO plan_sources(plan_id,account,source_kind,library_item_id,library_version_id,target_sha256,recorded_at) VALUES(?,?,'message_library',?,?,?,?)"
        values:@[plan, account, item, version, targetDigest, now]];
    [self query:@"INSERT INTO rules(id,plan_id,name,position,minimum,maximum) VALUES(?,?,'message_library',1,?,?)"
        values:@[rule, plan, @(minimum), @(maximum)]];
    NSUInteger position = 0;
    for (NSString *target in targets)
        [self query:@"INSERT INTO allocations(plan_id,target,rule_id,position) VALUES(?,?,?,?)"
            values:@[plan, target, rule, @(position++)]];
    [self query:@"INSERT INTO library_tasks(id,account,confirmation_id,item_id,version_id,plan_id,rule_id,frozen_snapshot,frozen_sha256,media_token,target_sha256,target_count,origin_task_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        values:@[task, account, confirmation, item, version, plan, rule, frozen, digest,
            token ?: (id)NSNull.null, targetDigest, @(targets.count), origin ?: (id)NSNull.null, now]];
    if ([token isKindOfClass:NSString.class] && [token length]) {
        // Only this account's own media record may be frozen and referenced.
        SRRequire([self query:@"SELECT token FROM media_assets WHERE token=? AND account=?" values:@[token, account]].count == 1,
                  @"Library media belongs to no media record of this account");
        [self query:@"INSERT OR IGNORE INTO media_references(account,token,owner_kind,owner_id,created_at) VALUES(?,?,'plan',?,?)"
            values:@[account, token, plan, now]];
        [self query:@"INSERT OR IGNORE INTO media_references(account,token,owner_kind,owner_id,created_at) VALUES(?,?,'history',?,?)"
            values:@[account, token, task, now]];
    }
    return task;
}

/* A confirmation ID is a request key, not a task pointer. Replaying one is only
 * allowed for a byte-for-byte identical request: same entry, same resolved
 * version, same ordered targets, same interval and the same operation origin
 * (a create has none, a re-send names the task it came from). Returns the stored
 * task for an identical retry, nil when the key is unused, and throws for every
 * other request instead of handing back a different task. */
- (NSString *)replayLibraryTaskUncheckedAccount:(NSString *)account confirmation:(NSString *)confirmation
                                           item:(NSString *)item version:(NSString *)version
                                        targets:(NSArray<NSString *> *)targets
                                        minimum:(double)minimum maximum:(double)maximum
                                         origin:(NSString *)origin {
    NSDictionary *existing = [self query:@"SELECT t.id,t.item_id,t.version_id,t.target_sha256,t.target_count,t.origin_task_id,r.minimum,r.maximum FROM library_tasks t JOIN rules r ON r.id=t.rule_id WHERE t.account=? AND t.confirmation_id=?"
        values:@[account, confirmation]].firstObject;
    if (!existing) return nil;
    // Digesting a malformed scope must fail as an invalid request, not as an
    // unexpected exception raised inside a string join.
    for (id target in targets)
        SRRequire([target isKindOfClass:NSString.class], @"Invalid target group");
    SRRequire([existing[@"item_id"] isEqual:item],
              @"This confirmation was already used for a different library entry");
    SRRequire([existing[@"version_id"] isEqual:version],
              @"This confirmation was already used for a different library version");
    SRRequire([existing[@"target_count"] isEqual:@(targets.count)] &&
              [existing[@"target_sha256"] isEqual:SRTargetDigest(targets)],
              @"This confirmation was already used for a different target scope or order");
    SRRequire(fabs([existing[@"minimum"] doubleValue] - minimum) < 1e-9 &&
              fabs([existing[@"maximum"] doubleValue] - maximum) < 1e-9,
              @"This confirmation was already used with a different send interval");
    SRRequire(SRSameOptionalValue(existing[@"origin_task_id"], origin),
              @"This confirmation was already used by a different operation or origin task");
    return existing[@"id"];
}

/* Reads one frozen task and re-verifies every freeze claim from durable rows. */
- (NSDictionary *)libraryTaskUnchecked:(NSString *)task account:(NSString *)account {
    NSMutableDictionary *row = [[self query:@"SELECT * FROM library_tasks WHERE id=? AND account=?" values:@[task, account]].firstObject mutableCopy];
    SRRequire(row != nil, @"Message-library task is unavailable for this account");
    SRRequire(SRDigestMatches(row[@"frozen_snapshot"], row[@"frozen_sha256"]), @"Frozen task snapshot was altered");
    NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:[row[@"frozen_snapshot"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    SRRequire([snapshot isKindOfClass:NSDictionary.class] && [snapshot[@"sourceKind"] isEqual:@"message_library"] &&
        [snapshot[@"itemID"] isEqual:row[@"item_id"]] && [snapshot[@"versionID"] isEqual:row[@"version_id"]] &&
        [snapshot[@"account"] isEqual:account], @"Frozen task source identity is inconsistent");
    for (NSString *key in @[@"group", @"sender", @"messageID"])
        SRRequire(snapshot[key] == nil, @"A message-library snapshot may not carry a group source identity");
    // The stored column must agree with the frozen payload. A task whose media
    // token was swapped after freezing would otherwise register a run-level
    // reference for a file the snapshot never named.
    id frozenPayload = snapshot[@"payload"];
    id frozenToken = [frozenPayload isKindOfClass:NSDictionary.class] ? frozenPayload[@"mediaReference"] : nil;
    if ([snapshot[@"type"] isEqual:@"image"]) {
        SRRequire([frozenToken isKindOfClass:NSString.class] && [frozenToken length],
                  @"Frozen image carries no media reference");
        SRRequire(SRSameOptionalValue(row[@"media_token"], frozenToken),
                  @"Frozen media reference differs from its stored column");
        SRRequire([self query:@"SELECT token FROM media_assets WHERE token=? AND account=?" values:@[frozenToken, account]].count == 1,
                  @"Frozen media belongs to no media record of this account");
    } else {
        SRRequire(frozenToken == nil && SRSameOptionalValue(row[@"media_token"], nil),
                  @"A frozen task without media may not carry a media reference");
    }
    NSDictionary *plan = [self query:@"SELECT account,source_group,snapshot FROM plans WHERE id=?" values:@[row[@"plan_id"]]].firstObject;
    SRRequire([plan[@"account"] isEqual:account] && [plan[@"source_group"] isEqual:@""] &&
        [plan[@"snapshot"] isEqual:row[@"frozen_snapshot"]], @"Frozen plan differs from its task");
    SRRequire([self query:@"SELECT plan_id FROM plan_sources WHERE plan_id=? AND source_kind='message_library' AND library_item_id=? AND library_version_id=?"
        values:@[row[@"plan_id"], row[@"item_id"], row[@"version_id"]]].count == 1, @"Frozen plan source is not registered");
    // The immutable version row must still belong to this entry and account.
    SRRequire([self query:@"SELECT id FROM library_versions WHERE id=? AND item_id=? AND account=?"
        values:@[row[@"version_id"], row[@"item_id"], account]].count == 1, @"Frozen library version is missing");
    NSArray *targets = [self query:@"SELECT target,position FROM allocations WHERE rule_id=? ORDER BY position ASC" values:@[row[@"rule_id"]]];
    SRRequire(targets.count == [row[@"target_count"] unsignedIntegerValue] && targets.count <= 20,
              @"Frozen target count was altered");
    SRRequire([SRTargetDigest([targets valueForKey:@"target"]) isEqual:row[@"target_sha256"]],
              @"Frozen target scope was altered");
    return [@{@"id": row[@"id"], @"confirmationID": row[@"confirmation_id"], @"itemID": row[@"item_id"],
        @"versionID": row[@"version_id"], @"planID": row[@"plan_id"], @"ruleID": row[@"rule_id"],
        @"runID": row[@"run_id"], @"mediaToken": row[@"media_token"], @"type": snapshot[@"type"],
        @"payload": snapshot[@"payload"], @"frozen": row[@"frozen_snapshot"], @"frozenSha256": row[@"frozen_sha256"],
        @"targetCount": row[@"target_count"], @"originTaskID": row[@"origin_task_id"], @"createdAt": row[@"created_at"],
        @"startedAt": row[@"started_at"], @"targets": targets, @"sourceKind": @"message_library",
        // This build implements storage, freeze and a start that only reserves
        // the account slot; it has written and verified no library send path, so
        // the card never claims one. "Not implemented" is the observed fact;
        // whether it needs a different ABI is untested and is not claimed here.
        @"dispatchAvailable": @NO} mutableCopy];
}

- (NSString *)createLibraryTaskForAccount:(NSString *)account item:(NSString *)item
                                  version:(nullable NSString *)version confirmationID:(NSString *)confirmationID
                                  targets:(NSArray<NSString *> *)targets
                                  minimum:(double)minimum maximum:(double)maximum error:(NSError **)error {
    return [self perform:^id{
        SRRequire(account.length && item.length, @"Account and library entry are required");
        SRRequire([confirmationID isKindOfClass:NSString.class] && confirmationID.length && confirmationID.length <= 200,
                  @"A confirmation ID is required to make a repeated confirmation idempotent");
        NSDictionary *entry = [self query:@"SELECT kind,current_version_id FROM library_items WHERE id=? AND account=? AND NOT EXISTS(SELECT 1 FROM library_deletions d WHERE d.item_id=library_items.id)"
            values:@[item, account]].firstObject;
        SRRequire(entry != nil, @"Library entry is unavailable for this account");
        // version=nil means "the entry's current version at first confirmation".
        // It is resolved once, before the replay check, so a retry after editing
        // the entry compares against the newly current version and is rejected
        // as a different request instead of silently switching versions.
        NSString *frozenVersion = version.length ? version : entry[@"current_version_id"];
        NSDictionary *stored = [self query:@"SELECT kind,payload FROM library_versions WHERE id=? AND item_id=? AND account=?"
            values:@[frozenVersion, item, account]].firstObject;
        SRRequire(stored != nil, @"Library version is unavailable for this account");
        // A repeated confirmation only resolves to a task whose whole request
        // matches; it can never be reused for other content, targets or pacing.
        NSString *replay = [self replayLibraryTaskUncheckedAccount:account confirmation:confirmationID
            item:item version:frozenVersion targets:targets minimum:minimum maximum:maximum origin:nil];
        if (replay) return replay;
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:[stored[@"payload"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        SRRequire([body isKindOfClass:NSDictionary.class], @"Stored library version is unreadable");
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE account=? AND archived_at IS NULL" values:@[account]].count == 0,
                  @"Handle the current group-sync content before freezing a library task");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count == 0,
                  @"An active run must end before another task is frozen");
        if ([stored[@"kind"] isEqual:@"image"]) {
            NSString *scope = [SRImageAssetStore libraryScopeForAccount:account];
            SRRequire(scope && [SRImageAssetStore validPayload:body] && [body[@"scopeSHA256"] isEqual:scope] &&
                [self.imageAssets dataForPayload:body scopeSHA256:scope error:NULL] != nil,
                @"Frozen image is missing or has changed; store it again");
        } else {
            SRRequire([body[@"text"] isKindOfClass:NSString.class] && [body[@"text"] length], @"Frozen text is empty");
        }
        NSDictionary *snapshot = [SRSourceMessage frozenJSON:@{@"type": stored[@"kind"], @"payload": body,
            @"account": account, @"sourceKind": @"message_library", @"itemID": item, @"versionID": frozenVersion,
            @"generatedByRelay": @NO}];
        SRRequire(snapshot != nil, @"Frozen library snapshot is not serializable");
        return [self createLibraryTaskUncheckedAccount:account item:item version:frozenVersion snapshot:snapshot
            targets:targets minimum:minimum maximum:maximum confirmation:confirmationID origin:nil];
    } transaction:YES error:error];
}

/* Explicit start of an already frozen task. The run begins awaiting_resume with
 * pending deliveries and no attempt; nothing is dispatched by this build. */
- (NSString *)startLibraryTask:(NSString *)task account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *frozen = [self libraryTaskUnchecked:task account:account];
        if (frozen[@"runID"] != NSNull.null) return frozen[@"runID"];
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE account=? AND archived_at IS NULL" values:@[account]].count == 0,
                  @"Handle the current group-sync content before starting a library task");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count == 0,
                  @"Another run already occupies this account");
        NSDictionary *rule = [self query:@"SELECT minimum,maximum FROM rules WHERE id=?" values:@[frozen[@"ruleID"]]].firstObject;
        SRRequire(rule != nil, @"Frozen rule is missing");
        NSString *run = NSUUID.UUID.UUIDString;
        NSNumber *now = @(NSDate.date.timeIntervalSince1970);
        [self query:@"INSERT INTO runs(id,rule_id,account,state,started_at,minimum,maximum,snapshot) VALUES(?,?,?,'awaiting_resume',?,?,?,?)"
            values:@[run, frozen[@"ruleID"], account, now, rule[@"minimum"], rule[@"maximum"], frozen[@"frozen"]]];
        NSUInteger position = 0;
        for (NSDictionary *target in frozen[@"targets"])
            [self query:@"INSERT INTO deliveries(id,run_id,target,position,state) VALUES(?,?,?,?,'pending')"
                values:@[NSUUID.UUID.UUIDString, run, target[@"target"], @(position++)]];
        [self query:@"UPDATE library_tasks SET run_id=?,started_at=? WHERE id=? AND account=? AND run_id IS NULL"
            values:@[run, now, task, account]];
        SRRequire(sqlite3_changes(self->_db) == 1, @"Task is already started or unknown");
        // Reference the token named by the frozen payload itself, never an
        // unverified column value, so a run can only retain a file the snapshot
        // actually froze. The read-back above already proved they agree.
        NSDictionary *sealed = [NSJSONSerialization JSONObjectWithData:[frozen[@"frozen"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        id sealedPayload = [sealed isKindOfClass:NSDictionary.class] ? sealed[@"payload"] : nil;
        id sealedToken = [sealedPayload isKindOfClass:NSDictionary.class] ? sealedPayload[@"mediaReference"] : nil;
        if ([sealedToken isKindOfClass:NSString.class] && [sealedToken length])
            [self query:@"INSERT OR IGNORE INTO media_references(account,token,owner_kind,owner_id,created_at) VALUES(?,?,'run',?,?)"
                values:@[account, sealedToken, run, now]];
        return run;
    } transaction:YES error:error];
}

/* Explicit re-send: a new task identity built from the original frozen bytes,
 * never from the editable library entry. The original task and every source
 * claim stay untouched. */
- (NSString *)resendLibraryTask:(NSString *)task account:(NSString *)account
                  confirmationID:(NSString *)confirmationID error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *origin = [self libraryTaskUnchecked:task account:account];
        SRRequire([confirmationID isKindOfClass:NSString.class] && confirmationID.length && confirmationID.length <= 200,
                  @"A new confirmation ID is required to re-send a frozen task");
        NSArray *targets = [origin[@"targets"] valueForKey:@"target"];
        NSDictionary *rule = [self query:@"SELECT minimum,maximum FROM rules WHERE id=?" values:@[origin[@"ruleID"]]].firstObject;
        SRRequire(rule != nil, @"Frozen rule is missing");
        // A re-send request is identified by the whole frozen scope plus the
        // original task and the operation itself: a key first used by a create
        // (origin NULL) or by another task's re-send is a different request and
        // is refused instead of returning that task.
        NSString *replay = [self replayLibraryTaskUncheckedAccount:account confirmation:confirmationID
            item:origin[@"itemID"] version:origin[@"versionID"] targets:targets
            minimum:[rule[@"minimum"] doubleValue] maximum:[rule[@"maximum"] doubleValue] origin:task];
        if (replay) return replay;
        SRRequire([self query:@"SELECT id FROM operations_contents WHERE account=? AND archived_at IS NULL" values:@[account]].count == 0,
                  @"Handle the current group-sync content before re-sending a frozen task");
        SRRequire([self query:@"SELECT id FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume') LIMIT 1" values:@[account]].count == 0,
                  @"An active run must end before a frozen task is re-sent");
        NSDictionary *source = [NSJSONSerialization JSONObjectWithData:[origin[@"frozen"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        SRRequire([source isKindOfClass:NSDictionary.class], @"Frozen task snapshot is unreadable");
        return [self createLibraryTaskUncheckedAccount:account item:origin[@"itemID"] version:origin[@"versionID"]
            snapshot:source targets:targets minimum:[rule[@"minimum"] doubleValue]
            maximum:[rule[@"maximum"] doubleValue] confirmation:confirmationID origin:task];
    } transaction:YES error:error];
}

- (NSDictionary *)libraryTask:(NSString *)task account:(NSString *)account error:(NSError **)error {
    return [self perform:^id{ return [self libraryTaskUnchecked:task account:account]; } transaction:NO error:error];
}

#pragma mark - Shared media budget

- (NSString *)mediaAlertPath {
    return [self.imageAssets.directory stringByAppendingPathComponent:SRMediaAlertFileName];
}

/* Reading usage never mutates the reminder flag; presenting is an explicit act. */
- (NSDictionary *)mediaUsageForAccount:(NSString *)account error:(NSError **)error {
    @synchronized (self) {
        if (!account.length) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Store" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Verified account is required"}];
            return nil;
        }
        id references = [self protectedMediaTokensError:NULL];
        // Unverified references may only make the reclaimable figure incomplete,
        // never smaller than the truth and never a fabricated zero.
        NSSet *verified = [references isKindOfClass:NSSet.class] ? references : nil;
        NSDictionary *usage = [self.imageAssets usageSnapshotProtectingTokens:verified error:error];
        if (!usage) return nil;
        SRMediaAlertState *state = [[SRMediaAlertState alloc] initWithPath:[self mediaAlertPath]];
        BOOL raised = NO;
        if (![state raisedForAccount:account raised:&raised error:error]) return nil;
        NSMutableDictionary *result = [usage mutableCopy];
        result[@"warningRaised"] = @(raised);
        return [result copy];
    }
}

- (NSNumber *)claimMediaWarningForAccount:(NSString *)account error:(NSError **)error {
    return [self claimMediaWarningForAccount:account policy:SRMediaDefaultPolicy() error:error];
}

/* @YES exactly once per upward 80% crossing (the default policy; the band is a
 * parameter, not a hardcoded product decision). @NO means "nothing to show".
 * Persisted per account so a panel reload or a restart does not repeat it. */
- (NSNumber *)claimMediaWarningForAccount:(NSString *)account policy:(SRMediaPolicy)policy error:(NSError **)error {
    @synchronized (self) {
        if (!account.length || !SRMediaPolicyIsValid(policy)) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Store" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Verified account and a valid media threshold policy are required"}];
            return nil;
        }
        id references = [self protectedMediaTokensError:NULL];
        NSSet *verified = [references isKindOfClass:NSSet.class] ? references : nil;
        SRMediaSnapshot snapshot;
        if (![self.imageAssets mediaSnapshot:&snapshot protectingTokens:verified error:error]) return nil;
        SRMediaAlertState *state = [[SRMediaAlertState alloc] initWithPath:[self mediaAlertPath]];
        BOOL raised = NO;
        if (![state raisedForAccount:account raised:&raised error:error]) return nil;
        SRMediaAlertAction action = SRMediaAlertStep(raised, snapshot, policy);
        if (action == SRMediaAlertRaise)
            return [state setRaised:YES forAccount:account error:error] ? @YES : nil;
        if (action == SRMediaAlertClear && ![state setRaised:NO forAccount:account error:error]) return nil;
        return @NO;
    }
}

/* A short, non-reversible display handle. The resource page must never show a
 * file name or a raw storage token, and a digest cannot be read back as bytes. */
static NSString *SRMediaIdentifier(NSString *token) {
    if (!token.length) return @"";
    NSString *digest = [SRImageAssetStore sha256ForData:[token dataUsingEncoding:NSUTF8StringEncoding]];
    return digest.length >= 8 ? [[digest substringToIndex:8] uppercaseString] : @"";
}
static NSString *SRTokenFromSnapshot(NSString *json) {
    NSData *data = [json isKindOfClass:NSString.class] ? [json dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSDictionary *snapshot = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *payload = [snapshot isKindOfClass:NSDictionary.class] && [snapshot[@"type"] isEqual:@"image"] ? snapshot[@"payload"] : nil;
    NSString *token = [payload isKindOfClass:NSDictionary.class] ? payload[@"mediaReference"] : nil;
    NSUUID *uuid = [token isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:token] : nil;
    return [uuid.UUIDString isEqual:token] ? token : nil;
}

/* Only this account's material is listed. A file that another account still
 * references is counted, never named, so the page cannot be used to enumerate
 * someone else's library. Unreferenced files are listed because they are the
 * only thing a cleanup could ever reclaim. */
- (NSDictionary *)mediaResourcesForAccount:(NSString *)account limit:(NSUInteger)limit error:(NSError **)error {
    @synchronized (self) {
        if (!account.length) {
            if (error) *error = [NSError errorWithDomain:@"SyncRelay.Store" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Verified account is required"}];
            return nil;
        }
        id references = [self protectedMediaTokensError:error];
        if (!references) return nil;
        NSSet *verified = [references isKindOfClass:NSSet.class] ? references : nil;
        NSArray *objects = [self.imageAssets mediaObjectsProtectingTokens:verified limit:limit error:error];
        if (!objects) return nil;
        NSMutableSet *mine = [NSMutableSet set], *running = [NSMutableSet set];
        for (NSDictionary *row in [self query:@"SELECT token FROM media_references WHERE account=? UNION SELECT token FROM media_assets WHERE account=?"
            values:@[account, account]]) [mine addObject:row[@"token"]];
        for (NSDictionary *row in [self query:@"SELECT snapshot FROM plans WHERE account=?" values:@[account]]) {
            NSString *token = SRTokenFromSnapshot(row[@"snapshot"]); if (token) [mine addObject:token];
        }
        for (NSDictionary *row in [self query:@"SELECT snapshot FROM runs WHERE account=? AND state IN ('running','paused','awaiting_resume')"
            values:@[account]]) {
            NSString *token = SRTokenFromSnapshot(row[@"snapshot"]);
            if (token) { [mine addObject:token]; [running addObject:token]; }
        }
        NSMutableArray *rows = [NSMutableArray array];
        NSUInteger other = 0;
        for (NSDictionary *object in objects) {
            BOOL temporary = [object[@"kind"] isEqual:@"temporary"];
            NSString *token = object[@"token"];
            // Reported as referenced by someone else: leave it out entirely.
            if (!temporary && token.length && verified && ![mine containsObject:token] && [object[@"referenced"] boolValue]) {
                other += 1; continue;
            }
            NSMutableDictionary *row = [object mutableCopy];
            if (verified) {
                row[@"referenced"] = @(!temporary && [mine containsObject:token]);
                row[@"reclaimable"] = @(!temporary && ![verified containsObject:token]);
            } else {
                // A damaged reference set is not proof of "unused".
                row[@"referenced"] = @(!temporary);
                row[@"reclaimable"] = @NO;
            }
            row[@"inUse"] = @([object[@"inUse"] boolValue] || (token.length && [running containsObject:token]));
            row[@"identifier"] = SRMediaIdentifier(token);
            [row removeObjectForKey:@"token"];
            [rows addObject:row];
        }
        NSUInteger cap = MIN(MAX(limit, (NSUInteger)1), (NSUInteger)500);
        return @{@"rows": [rows copy], @"otherAccountCount": @(other), @"referencesVerified": @(verified != nil),
            @"truncated": @(objects.count >= cap), @"listedCount": @(rows.count)};
    }
}
@end
