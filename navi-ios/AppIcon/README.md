# App icon

The icon is drawn in code rather than stored as an opaque bitmap, so it can be
re-coloured or re-shaped without a design tool.

```
swift GenerateIcon.swift ../NaviRemote/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

That writes the single 1024x1024 PNG the asset catalogue expects; Xcode derives
every other size. Nothing else needs to change.

Deleting this folder does not affect the build — it only removes the ability to
regenerate the artwork.
