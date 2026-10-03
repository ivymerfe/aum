@MainActor final class Config: ConfigCore {
    @UserDefault var betterLayoutSwitcher = true
    @UserDefault var betterScreenRotation = true
    @UserDefault var fastNavGesture = true
    @UserDefault var instantSpaceSwitcher = true
    @UserDefault var middleClickEmu = true
    @UserDefault var tapToClick = SystemPermissions.getIsSystemTapToClickEnabled
}
