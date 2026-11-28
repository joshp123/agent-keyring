// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Isolated resource target for the offline fallback favicon pack (`SiteIcons.bin`)
// and Public Suffix List (`psl.txt.zlib`), plus the k-anonymous static bucket client.
// Linked only by main Mac and iPhone app targets so notification/credential extensions
// never carry duplicate copies of these resources.

import Foundation

public enum SiteIconBundle {
    public static var url: URL? {
        Bundle.module.url(forResource: "SiteIcons", withExtension: "bin")
    }

    public static var pslURL: URL? {
        Bundle.module.url(forResource: "psl.txt", withExtension: "zlib")
            ?? Bundle.module.url(forResource: "psl", withExtension: "txt.zlib")
    }
}
