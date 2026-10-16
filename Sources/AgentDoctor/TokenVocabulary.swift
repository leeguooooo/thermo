import Foundation

// Official ordinary-text pre-tokenization rules, pinned to tiktoken 0.14.0.
enum TokenVocabulary {
    static let cl100kPattern = #"'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}++|\p{N}{1,3}+| ?[^\s\p{L}\p{N}]++[\r\n]*+|\s++$|\s*[\r\n]|\s+(?!\S)|\s"#
    static let cl100kHash = "0eaa490d6af2c7661690b5d35de1055dc5c946b8452dc980e6da7925bb1a9ff8"
    static let o200kPattern = #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    static let o200kHash = "87991f285e029d368443bf03c4aabf0225dd6d525a3a83d31a38f64617bec8df"
}
