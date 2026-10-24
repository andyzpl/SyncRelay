#define SR_PLUGIN_VERSION @"0.2.30+aprobe.5-ui.1"
#if __has_include("SRBuildRevision.h")
#import "SRBuildRevision.h"
#else
#define SR_BUILD_COMMIT @"working-tree"
#define SR_BUILD_RUN @"local"
#endif
