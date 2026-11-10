extension Workspace {
    @MainActor func normalizeContainers() {
        let root = rootTilingContainer
        root.unbindEmptyAndFlattenContainersRecursive(kept: containersAwaitingWindows(of: self))
        // rootTilingContainer.deriveAxLifeStatusRecursive()
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            root.normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: nil)
        }
    }
}

extension TilingContainer {
    /// This function has probably way too many responsibilities:
    /// 1. It unbinds empty containers
    /// 2. It flattens containers that contain only a single child (excluding the root container)
    /// 3. It sets correct lifeStatus values
    ///
    /// `kept` containers are neither flattened nor unbound: windows in a macOS native state come back to them (see
    /// TilingSlot). They become tombstones, like the containers of invisible windows
    ///
    /// todo: It's not clear what happens with mru in this function (does mru get rewritten by the recursive calls?).
    ///       Is it O(n^2) complexity?
    @MainActor fileprivate func unbindEmptyAndFlattenContainersRecursive(kept: Set<ObjectIdentifier>) {
        let isKept = kept.contains(ObjectIdentifier(self))
        if isRootContainer { // Special logic for root node to keep it always bound
            if let child = children.singleOrNil() as? TilingContainer, config.enableNormalizationFlattenContainers,
               !isKept, !kept.contains(ObjectIdentifier(child))
            {
                child.unbindFromParent()
                for grandChild in child.children {
                    let data = grandChild.unbindFromParent()
                    grandChild.bind(to: self, adaptiveWeight: data.adaptiveWeight, index: INDEX_BIND_LAST)
                }
                self.copyFrom(child)
            }
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndFlattenContainersRecursive(kept: kept)
            }
            self.lifeStatus = .alive
        } else if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers, !isKept {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent() // Kill the current node
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndFlattenContainersRecursive(kept: kept)
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            // Children that are flattened below are rebound to this container. Its lifeStatus from the previous
            // normalization may be stale (e.g. mustBeFlattened), and binding to not alive containers is illegal.
            // The actual lifeStatus is computed below
            lifeStatus = .alive
            var inhabitedChildrenCount = 0
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndFlattenContainersRecursive(kept: kept)
                inhabitedChildrenCount += child.tilingTreeNodeCasesOrDie().isInhabited ? 1 : 0
            }
            if children.isEmpty && !isKept {
                unbindFromParent()
            }
            if inhabitedChildrenCount == 1 && config.enableNormalizationFlattenContainers {
                lifeStatus = .mustBeFlattened
            } else {
                lifeStatus = inhabitedChildrenCount > 0 ? .alive : .deadOrInvisible
            }
        }
    }
}
