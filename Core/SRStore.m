#import "SRStore.h"
#import "SRPacing.h"
#import "SRConfiguration.h"
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

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &_db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (error) *error = [NSError errorWithDomain:@"SyncRelay.Store" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Cannot open relay database"}];
        return nil;
    }
    sqlite3_busy_timeout(_db, 5000);
    id setup = [self perform:^id{
        [self query:@"PRAGMA foreign_keys=ON" values:@[]];
        [self query:@"PRAGMA journal_mode=WAL" values:@[]];
        [self query:@"PRAGMA synchronous=FULL" values:@[]];
        NSInteger version = [[self query:@"PRAGMA user_version" values:@[]].firstObject[@"user_version"] integerValue];
        SRRequire(version >= 0 && version <= 2, @"Unsupported database schema; do not downgrade");
        return @YES;
    } transaction:NO error:error];
    if (!setup) return nil;
    id migrated = [self perform:^id{
        NSArray *schema = @[
            @"CREATE TABLE IF NOT EXISTS plans(id TEXT PRIMARY KEY, account TEXT NOT NULL, source_group TEXT NOT NULL, senders TEXT NOT NULL, types TEXT NOT NULL, snapshot TEXT NOT NULL)",
            @"CREATE TABLE IF NOT EXISTS rules(id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES plans(id), name TEXT NOT NULL, position INTEGER NOT NULL, minimum REAL NOT NULL CHECK(minimum>=10), maximum REAL NOT NULL CHECK(maximum>=minimum), UNIQUE(plan_id,position))",
            @"CREATE TABLE IF NOT EXISTS allocations(plan_id TEXT NOT NULL REFERENCES plans(id), target TEXT NOT NULL, rule_id TEXT NOT NULL REFERENCES rules(id), position INTEGER NOT NULL, PRIMARY KEY(plan_id,target))",
            @"CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY, rule_id TEXT NOT NULL REFERENCES rules(id), account TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('running','paused','awaiting_resume','completed','ended')), started_at REAL NOT NULL, ended_at REAL, minimum REAL NOT NULL, maximum REAL NOT NULL, snapshot TEXT NOT NULL)",
            @"CREATE UNIQUE INDEX IF NOT EXISTS one_active_run ON runs(account) WHERE state IN ('running','paused','awaiting_resume')",
            @"CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), target TEXT NOT NULL, position INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','submitting','confirmed','failed','uncertain','cancelled')), attempt_id TEXT, message_id TEXT, reason TEXT, UNIQUE(run_id,target))",
            @"CREATE INDEX IF NOT EXISTS delivery_queue ON deliveries(run_id,state,position)",
            @"CREATE TABLE IF NOT EXISTS attempts(id TEXT PRIMARY KEY, delivery_id TEXT NOT NULL REFERENCES deliveries(id), started_at REAL NOT NULL, ended_at REAL, state TEXT NOT NULL, message_id TEXT, reason TEXT)",
            @"CREATE TABLE IF NOT EXISTS configurations(account TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL)",
            @"PRAGMA user_version=2"
        ];
        for (NSString *sql in schema) [self query:sql values:@[]];
        return @YES;
    } transaction:YES error:error];
    return migrated ? self : nil;
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
        SRRequire(SRPacingConfigure(&pacing, minimum, maximum), @"Interval must satisfy 10 <= minimum <= maximum");
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
    return [self perform:^id{
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
    } transaction:YES error:error];
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
        [self query:@"UPDATE runs SET state='running' WHERE id=? AND state IN ('paused','awaiting_resume')" values:@[run]];
        SRRequire(sqlite3_changes(self->_db) == 1, @"Run is not paused");
        return @YES;
    } transaction:YES error:error] != nil;
}

- (BOOL)recoverInterruptedRuns:(NSError **)error {
    return [self perform:^id{
        [self query:@"UPDATE attempts SET state='uncertain',reason='Process interrupted' WHERE state='submitting'" values:@[]];
        [self query:@"UPDATE deliveries SET state='uncertain',reason='Process interrupted' WHERE state='submitting'" values:@[]];
        [self query:@"UPDATE runs SET state='awaiting_resume' WHERE state IN ('running','paused')" values:@[]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSDictionary *)claimNextForRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        NSDictionary *batch = [self query:@"SELECT state FROM runs WHERE id=?" values:@[run]].firstObject;
        SRRequire([batch[@"state"] isEqual:@"running"], @"Run is not running");
        SRRequire([self query:@"SELECT id FROM deliveries WHERE run_id=? AND state IN ('submitting','uncertain') LIMIT 1" values:@[run]].count == 0,
                  @"An in-flight or uncertain delivery needs resolution");
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
        SRRequire([@[@"confirmed", @"failed", @"uncertain"] containsObject:state], @"Invalid outcome");
        SRRequire(![state isEqual:@"confirmed"] || messageID.length, @"Confirmed result requires a correlated message ID");
        NSDictionary *row = [self query:@"SELECT * FROM deliveries WHERE id=? AND attempt_id=?" values:@[delivery, attempt]].firstObject;
        SRRequire(row != nil, @"Unmatched attempt");
        if (![row[@"state"] isEqual:@"submitting"] && ![row[@"state"] isEqual:@"uncertain"]) {
            SRRequire([row[@"state"] isEqual:state], @"Conflicting terminal callback");
            return @YES;
        }
        [self query:@"UPDATE deliveries SET state=?,message_id=?,reason=? WHERE id=?"
            values:@[state, messageID ?: (id)NSNull.null, reason ?: (id)NSNull.null, delivery]];
        [self query:@"UPDATE attempts SET state=?,ended_at=?,message_id=?,reason=? WHERE id=?"
            values:@[state, @(NSDate.date.timeIntervalSince1970), messageID ?: (id)NSNull.null, reason ?: (id)NSNull.null, attempt]];
        NSArray *remaining = [self query:@"SELECT id FROM deliveries WHERE run_id=? AND state!='confirmed' LIMIT 1" values:@[row[@"run_id"]]];
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
        [self query:@"UPDATE attempts SET state='uncertain',reason='Ended while submitting' WHERE delivery_id IN (SELECT id FROM deliveries WHERE run_id=? AND state='submitting')" values:@[run]];
        [self query:@"UPDATE deliveries SET state='uncertain',reason='Ended while submitting' WHERE run_id=? AND state='submitting'" values:@[run]];
        return @YES;
    } transaction:YES error:error] != nil;
}

- (NSDictionary *)summaryForRun:(NSString *)run error:(NSError **)error {
    return [self perform:^id{
        NSMutableDictionary *summary = [[self query:@"SELECT * FROM runs WHERE id=?" values:@[run]].firstObject mutableCopy];
        SRRequire(summary != nil, @"Unknown run");
        summary[@"counts"] = [self query:@"SELECT state,COUNT(*) AS count FROM deliveries WHERE run_id=? GROUP BY state" values:@[run]];
        return summary;
    } transaction:NO error:error];
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
@end
