#import <UIKit/UIKit.h>
@class SRStore;
NS_ASSUME_NONNULL_BEGIN

/* Read-only B-3 pages. They project what Core already stored: the message
 * library inventory and the shared media budget. Nothing here imports, edits,
 * deletes, cleans up, creates a task or sends; a page never calls a host image
 * getter, never prepares or downloads media, and keeps no second copy of any
 * business state.
 *
 * Every page re-verifies the account it was opened with before it reads or
 * shows anything, and refuses (rather than switching) when that account
 * changed. */
FOUNDATION_EXPORT UIViewController *SRCreateLibraryList(SRStore *store, NSString *account,
                                                        BOOL (^verifyAccount)(void));
FOUNDATION_EXPORT UIViewController *SRCreateLibraryItem(SRStore *store, NSString *account,
                                                        BOOL (^verifyAccount)(void), NSString *item);
FOUNDATION_EXPORT UIViewController *SRCreateMediaResources(SRStore *store, NSString *account,
                                                           BOOL (^verifyAccount)(void));
NS_ASSUME_NONNULL_END
