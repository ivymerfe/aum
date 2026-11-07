@MainActor final class Config: ConfigCore {
    @UserDefault var layoutSwitcher = true
    @UserDefault var inverseScrolling = true
    @UserDefault var touchRightClick = true
    @UserDefault var betterDisplayRotation = true
    @UserDefault var touchNavigation = true
    @UserDefault var spaceSwitcher = true
    @UserDefault var touchMiddleClick = true
    @UserDefault var tapToClick = SystemPermissions.getIsSystemTapToClickEnabled
    @UserDefault var appSwitcher = true
}
