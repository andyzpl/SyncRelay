#import "SRSelection.h"
@interface SRSelection ()
@property(nonatomic, copy) NSArray<NSDictionary *> *rows;
@property(nonatomic, strong) NSMutableSet<NSString *> *selected;
@property(nonatomic, copy) NSSet<NSString *> *available;
@end
@implementation SRSelection
- (instancetype)initWithRows:(NSArray<NSDictionary *> *)rows excludedIDs:(NSSet<NSString *> *)excluded selectedIDs:(NSSet<NSString *> *)selected {
    self = [super init];
    if (self) {
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableArray *allowed = [NSMutableArray array];
        for (NSDictionary *row in rows) {
            NSString *identifier = row[@"id"];
            if (!identifier.length || [excluded containsObject:identifier] || [seen containsObject:identifier]) continue;
            [allowed addObject:row]; [seen addObject:identifier];
        }
        _rows = [allowed copy]; _available = [seen copy]; _selected = [selected mutableCopy];
        [_selected intersectSet:_available];
    }
    return self;
}
- (NSArray *)rowsMatching:(NSString *)query {
    if (!query.length) return self.rows;
    return [self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, __unused NSDictionary *bindings) {
        return [row[@"name"] localizedCaseInsensitiveContainsString:query] || [row[@"id"] localizedCaseInsensitiveContainsString:query];
    }]];
}
- (NSArray *)selectedRows {
    return [self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, __unused NSDictionary *bindings) {
        return [self.selected containsObject:row[@"id"]];
    }]];
}
- (BOOL)isSelected:(NSString *)identifier { return [self.selected containsObject:identifier]; }
- (NSUInteger)selectedCount { return self.selected.count; }
- (void)toggle:(NSString *)identifier {
    if (![self.available containsObject:identifier]) return;
    if ([self.selected containsObject:identifier]) [self.selected removeObject:identifier];
    else [self.selected addObject:identifier];
}
- (void)selectFirst:(NSUInteger)count {
    [self.selected removeAllObjects];
    for (NSUInteger i = 0; i < MIN(count, self.rows.count); i++) [self.selected addObject:self.rows[i][@"id"]];
}
- (void)setRowsMatching:(NSString *)query selected:(BOOL)selected {
    for (NSDictionary *row in [self rowsMatching:query]) {
        if (selected) [self.selected addObject:row[@"id"]];
        else [self.selected removeObject:row[@"id"]];
    }
}
@end
