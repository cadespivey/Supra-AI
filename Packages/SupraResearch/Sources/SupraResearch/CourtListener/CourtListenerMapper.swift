import Foundation

public enum CourtListenerMapper {
    public static func displayURL(for result: CourtListenerSearchResultDTO) -> URL? {
        guard let absoluteURL = result.absoluteURL else {
            return nil
        }
        return URL(string: absoluteURL, relativeTo: CourtListenerEndpoint.baseURL)?.absoluteURL
    }

    public static func preferredCitation(for result: CourtListenerSearchResultDTO) -> String? {
        if let first = result.citation.first, !first.isEmpty {
            return first
        }
        if let neutralCite = result.neutralCite, !neutralCite.isEmpty {
            return neutralCite
        }
        if let lexisCite = result.lexisCite, !lexisCite.isEmpty {
            return lexisCite
        }
        return nil
    }
}
