# EXT4 Layer Cache Design

## Problem
Container creation takes 129 seconds because we unpack ALL image layers into a fresh EXT4 filesystem every time, even when many containers share the same base layers.

## Current Flow
```
Container Creation:
1. Create empty 8GB EXT4 filesystem (fast)
2. Unpack layer 1 (base debian) → ~40s
3. Unpack layer 2 (system packages) → ~30s
4. Unpack layer 3 (nodejs) → ~20s
5. Unpack layers 4-9 (app files) → ~39s
Total: ~129 seconds PER CONTAINER
```

## Proposed Solution: Incremental Layer Caching

### Architecture
```
~/.arca/cache/layers/
  └── sha256:{layer1_digest}/rootfs.ext4    ← Base layer only
  └── sha256:{layer1+2_digest}/rootfs.ext4  ← Base + layer 2
  └── sha256:{layer1+2+3_digest}/rootfs.ext4 ← Base + layer 2 + 3
  └── ...

~/.arca/containers/{container_id}/
  └── rootfs.ext4  ← CoW clone of cached state + remaining layers
```

### Flow for First nginx:latest Container
```
1. Check cache for layer1 digest → MISS
2. Create EXT4, unpack layer1 → 40s
3. Save to cache/layers/{layer1}/rootfs.ext4
4. Check cache for layer1+2 → MISS
5. Clone layer1 cache → 0.001s (CoW)
6. Unpack layer2 → 30s
7. Save to cache/layers/{layer1+2}/rootfs.ext4
... repeat for all layers
Total: ~129s (same as before, but now cached!)
```

### Flow for Second nginx:latest Container
```
1. Check cache for all 9 layers → HIT!
2. clonefile(cached_all_layers, container_rootfs) → 0.001s
3. Done!
Total: <1 second! 🚀
```

### Flow for apache:latest (shares base debian layer)
```
1. Check cache for layer1 (base debian) → HIT!
2. clonefile(cached_layer1, temp) → 0.001s
3. Check cache for layer1+apache_layer2 → MISS
4. Unpack apache_layer2 on temp → 20s
5. Save to cache
... continue for remaining apache layers
Total: ~60s (saved 40s from cached base layer!)
```

## Implementation Strategy

### Phase 1: Single-Layer Cache (Quick Win)
Cache only the final fully-unpacked image:
```swift
// Cache key: image digest (sha256:abc123...)
let cacheKey = imageDigest
let cachePath = ~/.arca/cache/images/{cacheKey}/rootfs.ext4

if FileManager.default.fileExists(cachePath) {
    // Clone cached filesystem (instant!)
    clonefile(cachePath, containerRootfs)
} else {
    // Unpack all layers, then cache result
    unpackAllLayers(to: containerRootfs)
    clonefile(containerRootfs, cachePath)
}
```
**Benefit**: 2nd nginx container = <1s instead of 129s

### Phase 2: Incremental Layer Cache (Maximum Efficiency)
Cache intermediate layer states:
```swift
var currentPath = createEmptyEXT4()
for (index, layer) in manifest.layers.enumerated() {
    let cacheKey = hash(layers[0...index]) // Cumulative hash
    let cachePath = ~/.arca/cache/layers/{cacheKey}/rootfs.ext4

    if FileManager.default.fileExists(cachePath) {
        // Use cached state for this layer combo
        currentPath = clonefile(cachePath, tempPath)
    } else {
        // Unpack this layer, then cache
        unpack(layer, onto: currentPath)
        clonefile(currentPath, cachePath)
    }
}
clonefile(currentPath, containerRootfs)
```
**Benefit**: apache container with shared base = ~60s instead of 129s

### Phase 3: Parallel Layer Fetching (Future)
Pre-fetch and cache popular base layers:
```
- debian:latest base → pre-cached
- ubuntu:latest base → pre-cached
- alpine:latest base → pre-cached
```

## Technical Details

### clonefile() Usage
```swift
import Darwin

func cloneFilesystem(from source: URL, to dest: URL) throws {
    let srcPath = source.path.withCString { $0 }
    let dstPath = dest.path.withCString { $0 }

    guard clonefile(srcPath, dstPath, 0) == 0 else {
        throw Error.cloneFailed(errno)
    }
}
```

### Cache Invalidation
- Cache persists across daemon restarts
- User can run `arca system prune --volumes` to clear cache
- No automatic expiration (user's disk, user's choice)

### Disk Usage
- CoW means clones share data blocks
- 10 nginx containers ≈ 1 nginx container disk usage
- Only modified blocks get duplicated (container writes)

## Performance Projections

### Current State
- 1st container: 129s
- 2nd container: 129s
- 3rd container: 129s

### With Phase 1 (Image Cache)
- 1st nginx: 129s (cache miss)
- 2nd nginx: <1s (cache hit)
- 1st apache: 129s (different image)
- 2nd apache: <1s (cache hit)

### With Phase 2 (Layer Cache)
- 1st nginx: 129s (all misses)
- 2nd nginx: <1s (all hits)
- 1st apache: ~60s (base hit, rest miss)
- 2nd apache: <1s (all hits)

## Next Steps
1. Implement Phase 1 (quick win, minimal code)
2. Test with real images
3. Measure actual performance gains
4. Implement Phase 2 if needed
