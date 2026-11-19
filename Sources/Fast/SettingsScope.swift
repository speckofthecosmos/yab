/// Ownership of an audited Settings row, independent of the selected space.
/// The annotation never changes the setting's storage or value.
enum SettingsScope: Equatable {
    /// One preference shared by every space. This does not imply device sync.
    case global
    /// A shared default that an individual space can override.
    case globalDefault
    /// A field or action on the particular space being edited.
    case space

    var title: String {
        switch self {
        case .global: return "All spaces"
        case .globalDefault: return "Default for spaces"
        case .space: return "This space"
        }
    }

    /// Deliberately explicit. Unknown rows have no annotation rather than an
    /// assumed global scope. In particular, Appearance preferences can wear
    /// the current space's paint, so their storage alone is not a scope proof.
    static func of(anchor: String) -> SettingsScope? {
        switch anchor {
        // SearchPage -> Preferences -> Store.settings. EngineChoice.space
        // falls back to EngineChoice.global unless Space.search overrides it.
        case "search-engine", "search-engine-custom":
            return .globalDefault
        // SearchPage and GeneralPage -> Preferences -> Store.settings.
        // Site aliases use Scopes' shared keywords/templates/off stores.
        case "search-suggest", "site-search", "warn-quit":
            return .global
        // SpacePage/SpaceSearchRows -> the selected Space's UUID.
        // Sign-ins chooses shared versus isolated storage for this space;
        // it does not claim the shared cookies belong to this space alone.
        case "space-name", "space-emoji", "space-color", "space-sign-ins",
             "space-delete", "space-search", "space-search-custom", "space-hide-from-ai":
            return .space
        default:
            return nil
        }
    }
}
