// AFNetworkActivityFileOutput.m
//
// Copyright (c) 2015 Tony Li
// Copyright (c) 2015 AFNetworking (http://afnetworking.com/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import <AFNetworking/AFURLConnectionOperation.h>
#import <AFNetworking/AFURLSessionManager.h>

#import "AFNetworkActivityFileOutput.h"
#import "AFNetworkActivityLogger.h"

static NSDateFormatter * AFNetworkActivityFileOutputDateFormatter()
{
    static NSDateFormatter *dateFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateStyle = NSDateFormatterMediumStyle;
        dateFormatter.timeStyle = NSDateFormatterMediumStyle;
    });
    return dateFormatter;
}

static NSString * AFNetworkActivityFileOutputDefaultPath() {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AFNetworkActivityLogger"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSString *filename = [[AFNetworkActivityFileOutputDateFormatter() stringFromDate:[NSDate date]] stringByAppendingString:@".log"];

    return [dir stringByAppendingPathComponent:filename];
}

@implementation AFNetworkActivityFileOutput {
    NSFileHandle *_fileHandle;
    dispatch_queue_t _fileQueue;
}

@synthesize level = _level;

- (instancetype)init
{
    return [self initWithFilePath:nil];
}

- (instancetype)initWithFilePath:(NSString *)path
{
    if ((self = [super init]) == nil) {
        return nil;
    }

    path = path ?: AFNetworkActivityFileOutputDefaultPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }

    _filePath = [path copy];
    _fileHandle = [NSFileHandle fileHandleForUpdatingAtPath:_filePath];
    [_fileHandle seekToEndOfFile];

    _fileQueue = dispatch_queue_create("com.afnetworking.AFNetworkActivityLogger.FileOutput", DISPATCH_QUEUE_SERIAL);

    return self;
}

- (void)dealloc
{
    [_fileHandle closeFile];
}

- (void)receiveRequestStartNotification:(NSNotification *)notification
{
    // Do nothing
}

- (void)receiveRequestFinishNotification:(NSNotification *)notification
{
    NSURLRequest *request = AFNetworkRequestFromNotification(notification);
    NSURLResponse *response = [notification.object response];
    NSError *error = AFNetworkErrorFromNotification(notification);
    NSDate *startDate = AFNetworkRequestStartDateFromNotification(notification);

    NSMutableArray *lines = [NSMutableArray array];
#define ADD_LINE(_line) \
  do { \
    id l = (_line); \
    if ([l isKindOfClass:[NSArray class]]) { \
      [lines addObjectsFromArray:l]; \
    } else if (l) { \
      [lines addObject:l]; \
    } \
  } while(0)

    // Log request content

#define LOG_REQUEST_INFO ADD_LINE(([NSString stringWithFormat:@">>> Request (%@)\n%@ %@", [AFNetworkActivityFileOutputDateFormatter() stringFromDate:startDate], request.HTTPMethod, request.URL]));

    switch (self.level) {
        case AFLoggerLevelDebug:
            LOG_REQUEST_INFO;
            ADD_LINE([self _requestContent:request]);
            break;
        case AFLoggerLevelInfo:
            LOG_REQUEST_INFO;
            break;
        case AFLoggerLevelWarn:
        case AFLoggerLevelError:
            if (error) {
                LOG_REQUEST_INFO;
            }
            break;
        default:
            break;
    }

    // Log response content

#define LOG_RESPONSE_INFO ADD_LINE(([NSString stringWithFormat:@"<<< Response (%@) [%.04f s]", [AFNetworkActivityFileOutputDateFormatter() stringFromDate:[NSDate date]], -[startDate timeIntervalSinceNow]]));

    switch (self.level) {
        case AFLoggerLevelDebug:
            LOG_RESPONSE_INFO;
            ADD_LINE([self _responseContent:response responsData:notification.userInfo[AFNetworkingTaskDidCompleteResponseDataKey]]);
            break;
        case AFLoggerLevelInfo:
            LOG_RESPONSE_INFO;
            break;
        case AFLoggerLevelWarn:
        case AFLoggerLevelError:
            if (error) {
                ADD_LINE([self _responseContent:response responsData:notification.userInfo[AFNetworkingTaskDidCompleteResponseDataKey]]);
                ADD_LINE(([NSString stringWithFormat:@"[Error] %@", error]));
            }
            break;
        default:
            break;
    }

    if (lines.count > 0) {
        ADD_LINE(@"----------");

        dispatch_async(_fileQueue, ^{
            NSString *text = [lines componentsJoinedByString:@"\n"];
            [_fileHandle writeData:[[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        });
    }
}

- (NSArray *)_requestContent:(NSURLRequest *)request
{
    NSMutableArray *lines = [NSMutableArray arrayWithArray:[self _headerFieldLines:request.allHTTPHeaderFields]];

    NSString *body = [[NSString alloc] initWithData:[request HTTPBody] encoding:NSUTF8StringEncoding];
    if (body.length > 0) {
        [lines addObject:body];
    }

    return lines;
}

- (NSArray *)_responseContent:(NSURLResponse *)response responsData:(NSData *)data
{
    if (response == nil) {
      return nil;
    }

    NSMutableArray *lines = [NSMutableArray array];

    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        [lines addObject:[response description]];
    } else {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        [lines addObject:[NSString stringWithFormat:@"%ld %@",
                          (long)httpResp.statusCode,
                          [NSHTTPURLResponse localizedStringForStatusCode:httpResp.statusCode]]];

        if (self.level == AFLoggerLevelDebug) {
            [lines addObjectsFromArray:[self _headerFieldLines:[httpResp allHeaderFields]]];
        }
    }

    if (data) {
        NSStringEncoding stringEncoding = NSUTF8StringEncoding;
        if (response.textEncodingName) {
            CFStringEncoding IANAEncoding = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)response.textEncodingName);
            if (IANAEncoding != kCFStringEncodingInvalidId) {
                stringEncoding = CFStringConvertEncodingToNSStringEncoding(IANAEncoding);
            }
        }

        NSString *responseString = [[NSString alloc] initWithData:data encoding:stringEncoding];
        if (responseString) {
            [lines addObject:responseString];
        }
    }

    return lines;
}

- (NSArray *)_headerFieldLines:(NSDictionary *)headers
{
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *field in [[headers allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        [lines addObject:[NSString stringWithFormat:@"%@: %@", field, headers[field]]];
    }
    return lines;
}

@end
