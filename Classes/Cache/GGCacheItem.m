//
//  GGCacheItem.m
//
//  Created by Evgeniy Shurakov on 16.04.12.
//  Copyright (c) 2012 AppCode. All rights reserved.
//

#import "GGCacheItem.h"

#include "sys/xattr.h"

enum {
	GGCacheItemOK = 0U,
	GGCacheItemNeedsWriteMeta = 1U << 0,
	GGCacheItemNeedsWriteData = 1U << 1
};

static const char * const metaKey = "appcode.ggcache.meta";

@interface GGCacheItem ()
@property(nonatomic, strong) NSString *key;
@property(nonatomic, assign) id proxy;
@end

@implementation GGCacheItem {
	NSString *_dataPath;
	
	NSData *_data;
	NSMutableDictionary *_meta;
	
	NSDate *_modificationDate;
	
	unsigned int state;
	
	// Due to ARC bug this is not weak
	__unsafe_unretained id _proxy;
}

@synthesize data=_data;
@synthesize key=_key;
@synthesize proxy=_proxy;

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key {
	return NO;
}

- (id)init {
	return [self initWithPath:nil];
}

- (id)initWithPath:(NSString *)path {
	self = [super init];
	if (self) {
		if (!path || [path length] == 0) {
			return nil;
		}
		
		_dataPath = path;
	}
	return self;
}

- (void)dealloc {
	_proxy = nil;
}

#pragma mark -

- (BOOL)write {
	if (!_dataPath) {
		return NO;
	}
	
	if ((state & GGCacheItemNeedsWriteData)) {
		state &= ~GGCacheItemNeedsWriteData;
		if (![_data writeToFile:_dataPath atomically:YES]) {
			state |= GGCacheItemNeedsWriteData;
			return NO;
		}
		
		_modificationDate = nil;
	}
	
	if ((state & GGCacheItemNeedsWriteMeta)) {
		state &= ~GGCacheItemNeedsWriteMeta;
		
		NSData *data = nil;
		if (_meta && [_meta count] > 0) {
			data = [NSKeyedArchiver archivedDataWithRootObject:_meta];
		}
		
		if (!data) {
			data = [NSData data];
		}
		
		int result = setxattr([_dataPath fileSystemRepresentation], metaKey, [data bytes], [data length], 0, 0);
				
		if (result != 0) {
			state |= GGCacheItemNeedsWriteMeta;
			return NO;
		}
	}
	return YES;
}

- (void)delete {
	[[NSFileManager defaultManager] removeItemAtPath:_dataPath error:nil];
	_modificationDate = nil;
}

- (BOOL)hasUnsavedChanges {
	return (state != GGCacheItemOK);
}

- (BOOL)inUse {
	return (_proxy != nil);
}

#pragma mark -

- (void)dehydrate {
	state = GGCacheItemOK;
	_data = nil;
	_meta = nil;
}

- (NSData *)data {
	if (!_data) {
		_data = [[NSData alloc] initWithContentsOfFile:_dataPath];
	}
	
	return _data;
}

- (void)setData:(NSData *)data {
	if (data == _data || (data && _data && [data isEqualToData:_data])) {
		return;
	}
	
	_data = data;
	
	[self setNeedsWriteData];
}

- (NSTimeInterval)age {	
	if ([self exists]) {
		if (!_modificationDate) {
			NSFileManager *fm = [NSFileManager defaultManager];
			NSDictionary *fileAttrs = [fm attributesOfItemAtPath:_dataPath error:NULL];
			_modificationDate = [fileAttrs objectForKey:NSFileModificationDate];
		}
				
		return -[_modificationDate timeIntervalSinceNow];
	} else {
		return DBL_MAX;
	}
}

- (void)setAge:(NSTimeInterval)age {
	if (![self exists]) {
		return;
	}
	
	_modificationDate = [NSDate dateWithTimeIntervalSinceNow:-age];
	
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableDictionary *fileAttrs = [[NSMutableDictionary alloc] initWithObjectsAndKeys:_modificationDate, NSFileModificationDate, nil];
	
	[fm setAttributes:fileAttrs 
		 ofItemAtPath:_dataPath 
				error:nil];
	
}

- (BOOL)exists {
	return [[NSFileManager defaultManager] fileExistsAtPath:_dataPath];
}

- (NSDictionary *)meta {
	return [self _meta];
}

- (void)setMeta:(NSDictionary *)meta {
	if (meta) {
		[[self _meta] setDictionary:meta];
	} else if (_meta) {
		[_meta removeAllObjects];
	} else {
		return;
	}
	
	[self setNeedsWriteMeta];
}

- (id)metaValueForKey:(NSString *)key {
	return [[self _meta] objectForKey:key];
}

- (void)setMetaValue:(id)value forKey:(NSString *)key {
	if (!key) {
		return;
	}
	
	if (value) {
		[[self _meta] setObject:value forKey:key];
	} else {
		[[self _meta] removeObjectForKey:key];
	}
	
	[self setNeedsWriteMeta];
}

#pragma mark -

- (void)setNeedsWriteMeta {
	if ((state & GGCacheItemNeedsWriteMeta)) {
		return;
	}
		
	if (state == GGCacheItemOK) {
		[self willChangeValueForKey:@"state"];
		state |= GGCacheItemNeedsWriteMeta;
		[self didChangeValueForKey:@"state"];
	} else {
		state |= GGCacheItemNeedsWriteMeta;
	}
	
}

- (void)setNeedsWriteData {
	if ((state & GGCacheItemNeedsWriteData)) {
		return;
	}
	
	if (state == GGCacheItemOK) {
		[self willChangeValueForKey:@"state"];
		state |= GGCacheItemNeedsWriteData;
		[self didChangeValueForKey:@"state"];
	} else {
		state |= GGCacheItemNeedsWriteData;
	}
}

- (NSMutableDictionary *)_meta {
	if (!_meta) {
		
		if ([self exists]) {
			const char *filepath = [_dataPath fileSystemRepresentation];
			
			ssize_t bufferLength = getxattr(filepath, metaKey, NULL, 0, 0, 0);
			
			if (bufferLength > 0) {
				char *buffer = malloc(bufferLength);
				getxattr(filepath, metaKey, buffer, bufferLength, 0, 0);
				
				NSData *data = [[NSData alloc] initWithBytesNoCopy:buffer
															length:bufferLength
													  freeWhenDone:YES];
				
				if (data) {
					_meta = [NSKeyedUnarchiver unarchiveObjectWithData:data];
					if (![_meta isKindOfClass:[NSDictionary class]]) {
						_meta = nil;
					} else if (![_meta respondsToSelector:@selector(setObject:forKey:)]) {
						_meta = [NSMutableDictionary dictionaryWithDictionary:_meta];
					}
				}
			}
		}
		
		if (!_meta) {
			_meta = [[NSMutableDictionary alloc] initWithCapacity:10];
		}
	}
	
	return _meta;
}

@end
