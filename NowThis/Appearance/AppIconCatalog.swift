import Foundation

struct AppIconCollection: Equatable, Sendable {
    let id: String
    let releasedAt: Date
}

struct AppIconDefinition {
    let id: String
    let alternateIconName: String?
    let previewAssetName: String
    let collectionID: String?
    let title: LocalizedStringResource
}

enum AppIconCatalog {
    static let icons: [AppIconDefinition] = [
        AppIconDefinition(id: "default", alternateIconName: nil, previewAssetName: "AppLogo", collectionID: nil, title: "Default"),
        AppIconDefinition(id: "supporter-2026", alternateIconName: "Supporter2026", previewAssetName: "Supporter2026Preview",
                          collectionID: "supporter-2026", title: "Supporter 2026"),
        AppIconDefinition(id: "supporter-midnight", alternateIconName: "SupporterMidnight", previewAssetName: "SupporterMidnightPreview",
                          collectionID: "supporter-2026", title: LocalizedStringResource("icon.midnight.title", defaultValue: "Midnight", comment: "Name of the dark navy Supporter app icon.")),
        AppIconDefinition(id: "supporter-confetti", alternateIconName: "SupporterConfetti", previewAssetName: "SupporterConfettiPreview",
                          collectionID: "supporter-2026", title: LocalizedStringResource("icon.confetti.title", defaultValue: "Confetti", comment: "Name of the colorful celebratory Supporter app icon.")),
        AppIconDefinition(id: "holiday-new-year", alternateIconName: "HolidayNewYear", previewAssetName: "HolidayNewYearPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.new-year.title", defaultValue: "New Year / Silvester", comment: "Name of the New Year / Silvester Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-valentine", alternateIconName: "HolidayValentine", previewAssetName: "HolidayValentinePreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.valentine.title", defaultValue: "Valentine’s Day", comment: "Name of the Valentine’s Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-spring", alternateIconName: "HolidaySpring", previewAssetName: "HolidaySpringPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.spring.title", defaultValue: "Spring", comment: "Name of the Spring Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-easter", alternateIconName: "HolidayEaster", previewAssetName: "HolidayEasterPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.easter.title", defaultValue: "Easter", comment: "Name of the Easter Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-halloween", alternateIconName: "HolidayHalloween", previewAssetName: "HolidayHalloweenPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.halloween.title", defaultValue: "Halloween", comment: "Name of the Halloween Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-harvest", alternateIconName: "HolidayHarvest", previewAssetName: "HolidayHarvestPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.harvest.title", defaultValue: "Harvest / Thanksgiving", comment: "Name of the Harvest / Thanksgiving Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-winter", alternateIconName: "HolidayWinter", previewAssetName: "HolidayWinterPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.winter.title", defaultValue: "Winter", comment: "Name of the Winter Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-christmas", alternateIconName: "HolidayChristmas", previewAssetName: "HolidayChristmasPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.christmas.title", defaultValue: "Christmas", comment: "Name of the Christmas Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-advent", alternateIconName: "HolidayAdvent", previewAssetName: "HolidayAdventPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.advent.title", defaultValue: "Advent", comment: "Name of the Advent Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-nikolaus", alternateIconName: "HolidayNikolaus", previewAssetName: "HolidayNikolausPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.nikolaus.title", defaultValue: "Nikolaus", comment: "Name of the Nikolaus Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-saint-martin", alternateIconName: "HolidaySaintMartin", previewAssetName: "HolidaySaintMartinPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.saint-martin.title", defaultValue: "Saint Martin", comment: "Name of the Saint Martin Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-carnival", alternateIconName: "HolidayCarnival", previewAssetName: "HolidayCarnivalPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.carnival.title", defaultValue: "Karneval / Fasching / Fasnacht", comment: "Name of the Karneval / Fasching / Fasnacht Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-oktoberfest", alternateIconName: "HolidayOktoberfest", previewAssetName: "HolidayOktoberfestPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.oktoberfest.title", defaultValue: "Oktoberfest", comment: "Name of the Oktoberfest Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-german-unity", alternateIconName: "HolidayGermanUnity", previewAssetName: "HolidayGermanUnityPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.german-unity.title", defaultValue: "German Unity Day", comment: "Name of the German Unity Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-swiss-national", alternateIconName: "HolidaySwissNational", previewAssetName: "HolidaySwissNationalPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.swiss-national.title", defaultValue: "Swiss National Day", comment: "Name of the Swiss National Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-kings-day", alternateIconName: "HolidayKingsDay", previewAssetName: "HolidayKingsDayPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.kings-day.title", defaultValue: "King’s Day / Koningsdag", comment: "Name of the King’s Day / Koningsdag Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-sinterklaas", alternateIconName: "HolidaySinterklaas", previewAssetName: "HolidaySinterklaasPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.sinterklaas.title", defaultValue: "Sinterklaas", comment: "Name of the Sinterklaas Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-france-national", alternateIconName: "HolidayFranceNational", previewAssetName: "HolidayFranceNationalPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.france-national.title", defaultValue: "France — 14 July", comment: "Name of the France — 14 July Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-france-may", alternateIconName: "HolidayFranceMay", previewAssetName: "HolidayFranceMayPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.france-may.title", defaultValue: "France — May Day", comment: "Name of the France — May Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-epiphany", alternateIconName: "HolidayEpiphany", previewAssetName: "HolidayEpiphanyPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.epiphany.title", defaultValue: "Epiphany / Three Kings", comment: "Name of the Epiphany / Three Kings Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-bonfire-night", alternateIconName: "HolidayBonfireNight", previewAssetName: "HolidayBonfireNightPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.bonfire-night.title", defaultValue: "Bonfire Night", comment: "Name of the Bonfire Night Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-hogmanay", alternateIconName: "HolidayHogmanay", previewAssetName: "HolidayHogmanayPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.hogmanay.title", defaultValue: "Hogmanay", comment: "Name of the Hogmanay Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-saint-patrick", alternateIconName: "HolidaySaintPatrick", previewAssetName: "HolidaySaintPatrickPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.saint-patrick.title", defaultValue: "Saint Patrick’s Day", comment: "Name of the Saint Patrick’s Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-saint-david", alternateIconName: "HolidaySaintDavid", previewAssetName: "HolidaySaintDavidPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.saint-david.title", defaultValue: "Saint David’s Day", comment: "Name of the Saint David’s Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-canada-day", alternateIconName: "HolidayCanadaDay", previewAssetName: "HolidayCanadaDayPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.canada-day.title", defaultValue: "Canada Day", comment: "Name of the Canada Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-saint-jean", alternateIconName: "HolidaySaintJean", previewAssetName: "HolidaySaintJeanPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.saint-jean.title", defaultValue: "Saint-Jean-Baptiste", comment: "Name of the Saint-Jean-Baptiste Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-us-independence", alternateIconName: "HolidayUsIndependence", previewAssetName: "HolidayUsIndependencePreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.us-independence.title", defaultValue: "US — Independence Day", comment: "Name of the US — Independence Day Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-midsummer", alternateIconName: "HolidayMidsummer", previewAssetName: "HolidayMidsummerPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.midsummer.title", defaultValue: "Midsummer", comment: "Name of the Midsummer Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-hanukkah", alternateIconName: "HolidayHanukkah", previewAssetName: "HolidayHanukkahPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.hanukkah.title", defaultValue: "Hanukkah", comment: "Name of the Hanukkah Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-passover", alternateIconName: "HolidayPassover", previewAssetName: "HolidayPassoverPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.passover.title", defaultValue: "Passover / Pesach", comment: "Name of the Passover / Pesach Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-ramadan", alternateIconName: "HolidayRamadan", previewAssetName: "HolidayRamadanPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.ramadan.title", defaultValue: "Ramadan", comment: "Name of the Ramadan Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-eid", alternateIconName: "HolidayEid", previewAssetName: "HolidayEidPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.eid.title", defaultValue: "Eid", comment: "Name of the Eid Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-diwali", alternateIconName: "HolidayDiwali", previewAssetName: "HolidayDiwaliPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.diwali.title", defaultValue: "Diwali", comment: "Name of the Diwali Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-holi", alternateIconName: "HolidayHoli", previewAssetName: "HolidayHoliPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.holi.title", defaultValue: "Holi", comment: "Name of the Holi Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-vaisakhi", alternateIconName: "HolidayVaisakhi", previewAssetName: "HolidayVaisakhiPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.vaisakhi.title", defaultValue: "Vaisakhi", comment: "Name of the Vaisakhi Supporter holiday app icon.")),
        AppIconDefinition(id: "holiday-vesak", alternateIconName: "HolidayVesak", previewAssetName: "HolidayVesakPreview",
                          collectionID: "supporter-holidays-2026", title: LocalizedStringResource("icon.holiday.vesak.title", defaultValue: "Vesak", comment: "Name of the Vesak Supporter holiday app icon."))
    ]
    static let collections = [
        AppIconCollection(id: "supporter-2026", releasedAt: Date(timeIntervalSince1970: 1_790_899_200)), // 2026-10-02 UTC
        AppIconCollection(id: "supporter-holidays-2026", releasedAt: Date(timeIntervalSince1970: 1_792_800_000)) // 2026-10-24 UTC
        // New collections use their release date so paid-period ownership remains accurate.
    ]
}
