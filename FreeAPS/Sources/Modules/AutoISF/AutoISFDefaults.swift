extension AutoISF.StateModel {
    func resetAutoISFDefaults() {
        autoisf = false
        enableBGacceleration = true
        autoisf_min = 0.8
        autoisf_max = 1.2
        smbDeliveryRatioBGrange = 0
        smbDeliveryRatioMin = 0.5
        smbDeliveryRatioMax = 0.5
        autoISFhourlyChange = 0.2
        higherISFrangeWeight = 0
        lowerISFrangeWeight = 0
        postMealISFweight = 0.01
        bgAccelISFweight = 0
        bgBrakeISFweight = 0.10
        iobThresholdPercent = 60
    }

    func resetB30Defaults() {
        use_B30 = false
        iTime_Start_Bolus = 1.5
        b30targetLevel = 100
        b30upperLimit = 130
        b30upperdelta = 8
        b30factor = 5
        b30_duration = 30
    }

    func resetKetoDefaults() {
        ketoProtect = false
        variableKetoProtect = false
        ketoProtectAbsolut = false
        ketoProtectBasalPercent = 20
        ketoProtectBasalAbsolut = 0
    }
}
