#import "SRStore.h"
#import "SRPacing.h"
#import "SRConfiguration.h"
#import "SRSourceMessage.h"
#import "SRImageAssetStore.h"
#import <sqlite3.h>

@interface SRStore () {
    sqlite3 *_db;
}
@end

@implementation SRStore

static void SRRequire(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"SRStoreError" reason:message userInfo:nil];
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
        SRRequire(version >= 0 && version <= 8, @"Unsupported database schema; do not downgrade");
        if (version < 8) {
            rebuildRules = [self query:@"SELECT name FROM sqlite_master WHERE type='table' AND name='rules'" values:@[]].count > 0;
            [self query:@"PRAGMA foreign_keys=OFF" values:@[]];
        }
        return @YES;
    } transaction:NO error:error];
    if (!setup) return nil;
    id migrated = [self perform:^id{
        NSArray *schema = @[
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
            @"CREATE TABLE IF NOT EXISTS native_attempt_claims(delivery_id TEXT PRIMARY KEY REFERENCES deliveries(id), attempt_id TEXT NOT NULL UNIQUE REFERENCES attempts(id), claimed_at REAL NOT NULL)"
        ];
        for (NSString *sql in schema) [self query:sql values:@[]];
        if (rebuildRules) [self migrateRuleIntervalConstraint];
        if (version < 8) {
            SRRequire([self query:@"PRAGMA foreign_key_check" values:@[]].count == 0,
                      @"Database migration found broken foreign key references");
            [self query:@"PRAGMA user_version=8" values:@[]];
        }
        return @YES;
    } transaction:YES error:error];
    id enforced = [self perform:^id{
        [self query:@"PRAGMA foreign_keys=ON" values:@[]];
        SRRequire([[self query:@"PRAGMA foreign_keys" values:@[]].firstObject[@"foreign_keys"] boolValue],
                  @"Database foreign key enforcement is unavailable");
        return @YES;
    } transaction:NO error:migrated ? error : NULL];
    if (!migrated || !enforced) return nil;
    id retained = [self perform:^id{
        NSMutableSet *references = [NSMutableSet set];
        for (NSDictionary *row in [self query:@"SELECT snapshot FROM plans" values:@[]]) {
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
        return references;
    } transaction:NO error:error];
    if (!retained) return nil;
    if (retained != NSNull.null) [self.imageAssets pruneUnreferenced:retained];
    return self;
}

- (void)dealloc { if (_db) sqlite3_close(_db); }

- (NSString *)json:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    SRRequire(data != nil, @"Invalid source snapshot");
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
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

- (BOOL)resumeRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
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
        [self query:@"UPDATE runs SET state='completed',ended_at=? WHERE state='awaiting_resume' AND EXISTS(SELECT 1 FROM deliveries d WHERE d.run_id=runs.id) AND NOT EXISTS(SELECT 1 FROM deliveries d WHERE d.run_id=runs.id AND d.state IN ('pending','submitting'))"
            values:@[@(NSDate.date.timeIntervalSince1970)]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSDictionary *)claimNextForRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
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
        if (!remaining.count) [self query:@"UPDATE runs SET state='completed',ended_at=? WHERE id=? AND state IN ('running','paused','awaiting_resume')"
            values:@[@(NSDate.date.timeIntervalSince1970), row[@"run_id"]]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (BOOL)endRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
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
    } transaction:YES error:error];
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
            NSDictionary *latest = [self query:@"SELECT id,rule_id,state,started_at,ended_at,minimum,maximum FROM runs WHERE rule_id=? ORDER BY rowid DESC LIMIT 1" values:@[rule[@"id"]]].firstObject;
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
        for (NSDictionary *row in [self query:@"SELECT id,rule_id,state,started_at,ended_at,minimum,maximum FROM runs WHERE rule_id=? ORDER BY rowid DESC LIMIT ? OFFSET ?" values:@[rule, @(limit), @(offset)]])
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
@end
