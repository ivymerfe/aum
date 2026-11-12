@MainActor final class Config: ConfigCore {
    @UserDefault var altKeys = true
    @UserDefault var layoutSwitcher = true
    @UserDefault var windowControls = true

    @UserDefault var betterDisplayRotation = true
    @UserDefault var inverseScrolling = true

    @UserDefault var cmdTabSwitcher = true
    @UserDefault var altTapSwitcher = true
    @UserDefault var groupSwitcher = true
    @UserDefault var gestureSwitcher = true

    @UserDefault var specialBundles: Set<String> = [
        "com.brave.Browser",
        "com.apple.finder",
        "com.googlecode.iterm2",
        "com.apple.Safari",
    ]

    @UserDefault var touchMiddleClick = true
    @UserDefault var tapToClick = SystemPermissions.getIsSystemTapToClickEnabled
    @UserDefault var touchNavigation = true
    @UserDefault var touchRightClick = true
}
