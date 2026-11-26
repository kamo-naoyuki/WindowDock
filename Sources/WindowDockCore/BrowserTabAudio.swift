/// What a Chromium browser tab's accessibility label says about its sound. Chrome names each tab after its title
/// followed by its most important alert, such as "Title - Audio playing", in Chrome's interface language.
public enum BrowserTabAudio: Equatable, Sendable {
    case playing
    case muted
    /// Another alert (camera, screen sharing, picture in picture, or an unknown language) hides whether it plays.
    case otherAlert
    case silent

    /// `hasAlertIndicator` tells whether the tab shows an alert icon; it's only called for unrecognized labels.
    public init(name: String, hasAlertIndicator: () -> Bool) {
        if Self.playingMarkers.contains(where: { name.contains($0) }) {
            self = .playing
        } else if Self.mutedMarkers.contains(where: { name.contains($0) }) {
            self = .muted
        } else {
            self = hasAlertIndicator() ? .otherAlert : .silent
        }
    }

    /// Whether the tab may be the one playing its application's audio.
    public var mayBePlaying: Bool { self == .playing || self == .otherAlert }

    private static let playingMarkers = Set(markers.map(\.playing))
    private static let mutedMarkers = Set(markers.map(\.muted))

    /// The text Chrome appends to a tab's name when it plays audio and when it is muted
    /// (IDS_TAB_AX_LABEL_AUDIO_PLAYING_FORMAT and IDS_TAB_AX_LABEL_AUDIO_MUTING_FORMAT), by interface language.
    /// No language's playing text contains a muted text or the other way around.
    private static let markers: [(language: String, playing: String, muted: String)] = [
        ("en", " - Audio playing", " - Audio muted"),
        ("af", " – Oudio speel tans", " – Oudio is gedemp"),
        ("am", " - ኦዲዮ በመጫወት ላይ ነው", " - ኦዲዮ ድምፀ-ከል ተደርጎበታል"),
        ("ar", " - تشغيل الصوت", " - تم كتم الصوت"),
        ("as", " - অডিঅ' প্লে' কৰি থকা হৈছে", " - অডিঅ’ মিউট কৰা হৈছে"),
        ("az", " - Audio oxudulur", " - Audio səssiz edildi"),
        ("be", "\u{00A0}– прайграецца гук", "\u{00A0}– гук выключаны"),
        ("bg", " – възпроизвежда се звук", " – звукът е заглушен"),
        ("bn", " - অডিও বাজছে", " - অডিও মিউট রয়েছে"),
        ("bs", " – Reproduciranje zvuka", " – zvuk je isključen"),
        ("ca", ": s'està reproduint àudio", ": l'àudio està desactivat"),
        ("cs", " – přehrává se zvuk", " – zvuk je vypnutý"),
        ("cy", " - Yn chwarae sain", " - Sain wedi'i ddistewi"),
        ("da", " – der afspilles lyd", " – lyden er slået fra"),
        ("de", " – Audiowiedergabe", " – stummgeschaltet"),
        ("el", " - Αναπαραγωγή ήχου", " - Ο ήχος τέθηκε σε σίγαση"),
        ("en-GB", " – Audio playing", " – Audio muted"),
        ("es", ": reproducción de audio", ": audio silenciado"),
        ("es-419", ": Reproducción de audio", ": Audio silenciado"),
        ("et", " – heli esitatakse", " – heli on vaigistatud"),
        ("eu", " - Audioa erreproduzitzen ari da", " - Audioa desaktibatuta"),
        ("fa", " - پخش خودکار", " - بی\u{200C}صدا شده است"),
        ("fi", " – toistaa ääntä", " – ääni mykistetty"),
        ("fil", " - May tumutugtog na audio", " - Naka-mute ang audio"),
        ("fr", "\u{00A0}–\u{00A0}Lecture audio", "\u{00A0}–\u{00A0}Son coupé"),
        ("fr-CA", " - Lecture audio", " - Audio désactivé"),
        ("gl", ": reproducindo audio", ": audio silenciado"),
        ("gu", " - ઑડિઓ ચલાવવું", " - ઑડિઓ મ્યૂટ કર્યો"),
        ("hi", " - ऑडियो चलाया जा रहा है", " - ऑडियो म्यूट किया गया"),
        ("hr", " – reprodukcija zvuka", " – zvuk je isključen"),
        ("hu", " – Hanglejátszás", " – Hang kikapcsolva"),
        ("hy", " – Աուդիոնվագարկում", " – Ձայնն անջատված է"),
        ("id", " - Pemutaran audio", " - Audio dibisukan"),
        ("is", " – hljóð í spilun", " – slökkt á hljóði"),
        ("it", " - Riproduzione audio in corso", " - Audio disattivato"),
        ("iw", " - אודיו מופעל", " - האודיו הושתק"),
        ("ja", " - オーディオ再生中です", " - オーディオがミュートされています"),
        ("ka", " — უკრავს აუდიო", " — აუდიო დადუმებულია"),
        ("kk", " – аудиомазмұн ойнату", " – дыбысы өшірілді"),
        ("km", " - កំពុង\u{200B}ចាក់\u{200B}សំឡេង", " - បានបិទ\u{200B}\u{200B}សំឡេង\u{200B}"),
        ("kn", " - ಆಡಿಯೋ ಪ್ಲೇ ಆಗುತ್ತಿದೆ", " - ಆಡಿಯೋ ಮ್ಯೂಟ್ ಮಾಡಲಾಗಿದೆ"),
        ("ko", " - 오디오 재생", " - 오디오 음소거"),
        ("ky", " – Аудио файл ойнотулууда", " – Аудионун үнү өчүрүлгөн"),
        ("lo", " - ກຳລັງຫຼິ້ນສຽງ", " - ປິດສຽງແລ້ວ"),
        ("lt", "“ – garso įrašo paleidimas", "“ – garso įrašas nutildytas"),
        ("lv", "\u{00A0}— audio atskaņošana", "\u{00A0}— izslēgta skaņa"),
        ("mk", " - пуштено е аудио", " - звукот е исклучен"),
        ("ml", " - ഓഡിയോ പ്ലേ ചെയ്യുന്നു", " - ഓഡിയോ മ്യൂട്ടുചെയ്\u{200C}തു"),
        ("mn", " - Аудио тоглуулж байна", " - Аудионы дууг хаасан"),
        ("mr", " - ऑडिओ प्ले करीत आहे", " - ऑडिओ म्यूट केला"),
        ("ms", " - Audio sedang dimainkan", " - Audio diredam"),
        ("my", " - အသံဖွင့်ခြင်း", " - အသံပိတ်ရန်"),
        ("ne", " - अडियो बज्दैछ", " - अडियो म्यूट गरिएको छ"),
        ("nl", ": audio wordt afgespeeld", ": audio uitgezet"),
        ("no", " – lyd spilles av", " – lyden er kuttet"),
        ("or", " - ଅଡିଓ ବାଜୁଛି", " - ଅଡିଓକୁ ମ୍ୟୁଟ୍ କରାଗଲା"),
        ("pa", " - ਆਡੀਓ ਚਲਾਉਣਾ", " - ਆਡੀਓ ਮਿਊਟ ਕੀਤਾ"),
        ("pl", " – odtwarzanie dźwięku", " – dźwięk wyciszony"),
        ("pt-BR", " - Reprodução de áudio", " - Áudio desativado"),
        ("pt-PT", " – áudio em reprodução", " – áudio desativado"),
        ("ro", " – se redă sunet", " – sunetul a fost dezactivat"),
        ("ru", ": воспроизводится аудио", ": звук отключен"),
        ("si", " - ශ්\u{200D}රව්\u{200D}ය ධාවනය", " - ශ්\u{200D}රව්\u{200D}ය නිහඬ කළ"),
        ("sk", " – Prehráva sa zvuk", " – Vypnuté zvuky"),
        ("sl", " – zvok se predvaja", " – zvok utišan"),
        ("sq", " - po luhet audioja", " - audioja u çaktivizua"),
        ("sr", " – Пушта се аудио садржај", " – Звук је искључен"),
        ("sr-Latn", " – Pušta se audio sadržaj", " – Zvuk je isključen"),
        ("sv", " – spelar upp ljud", " – ljud av"),
        ("sw", " - Kucheza sauti", " - Sauti imezimwa"),
        ("ta", " - ஆடியோ இயக்கப்படுகிறது", " - ஆடியோ முடக்கப்பட்டது"),
        ("te", " - ఆడియో ప్లే చేస్తోంది", " - ఆడియో మ్యూట్ చేయబడింది"),
        ("th", " - เล่นอัตโนมัติ", " - ปิดเสียงอยู่"),
        ("tr", " - Ses çalıyor", " - Ses kapatıldı"),
        ("uk", " – відтворюється аудіо", " – звук вимкнено"),
        ("ur", " - آڈیو چلا رہی ہے", " - آڈیو خاموش ہے"),
        ("uz", " – audio ijro etilmoqda", " – ovozsiz qilindi"),
        ("vi", " - Phát âm thanh", " - Đã tắt âm thanh"),
        ("zh-CN", " - 正在播放音频", " - 音频已静音"),
        ("zh-HK", " - 正在播放音訊", " - 靜音"),
        ("zh-TW", " - 音訊播放中", " - 靜音"),
        ("zu", " - Kudlalwa umsindo", " - Umsindo uthulisiwe"),
    ]
}
