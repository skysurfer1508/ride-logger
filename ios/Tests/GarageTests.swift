import XCTest

final class GarageDecodingTests: XCTestCase {
    private func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try JSONDecoder.ridelog.decode(T.self, from: Data(contentsOf: url))
    }

    func testTheOverview() throws {
        let overview: GarageOverview = try load("api_garage")
        let bike = try XCTUnwrap(overview.bikes.first)
        XCTAssertEqual(bike.name, "Tuono")
        XCTAssertTrue(bike.isDefault)
        XCTAssertEqual(bike.subtitle, "Aprilia 1100 RR 2021")
        XCTAssertEqual(bike.odometerKm, 10360.7, accuracy: 0.001)
        XCTAssertEqual(bike.overdue, 0)
        XCTAssertNil(bike.nextDue)
    }

    func testTheBikeDetail() throws {
        let detail: BikeDetail = try load("api_garage_bike")
        XCTAssertEqual(detail.bike.startDate, "2026-01-01")
        XCTAssertEqual(detail.bike.riddenKm, 360.7, accuracy: 0.001)
        let item = try XCTUnwrap(detail.items.first)
        XCTAssertEqual(item.name, "Oil change")
        XCTAssertEqual(item.intervalText, "every 6000 km or 12 months")
        XCTAssertEqual(item.status.serviceState, .ok)
        XCTAssertEqual(item.status.dueDate, "2027-06-01")
        XCTAssertEqual(item.status.limitedBy, "date")
        XCTAssertEqual(detail.serviceLog.first?.cost, 180.5)
        XCTAssertEqual(detail.serviceLog.first?.itemName, "Oil change")
        XCTAssertEqual(detail.fuel.fills.count, 2)
        XCTAssertEqual(detail.fuel.fills[0].lPer100km, 4.4)                                  // newest first
        XCTAssertNil(detail.fuel.fills[1].lPer100km)                                          // the first full tank is only a starting point
        XCTAssertEqual(detail.fuel.averageLPer100km, 4.4)
        XCTAssertEqual(detail.fuel.totalSpent, 47.1, accuracy: 0.001)
        XCTAssertTrue(detail.fuel.fills[0].fullTank)
        XCTAssertEqual(detail.expenses.first?.category, "Tyres")
        XCTAssertEqual(detail.totals.all, 407.6, accuracy: 0.001)
        XCTAssertEqual(detail.totals.perKm, 1.13)
    }

    func testAMutationAnswerCarriesTheNewBikeIdAndStillDecodes() throws {
        let json = #"{"api":1,"bike_id":7,"bike":{"id":7,"name":"X","make":"","model":"","year":null,"is_default":true,"start_odometer_km":0,"start_date":"2026-10-02","odometer_km":0,"ridden_km":0},"items":[],"service_log":[],"fuel":{"fills":[],"average_l_per_100km":null,"measured_km":0,"total_litres":0,"total_spent":0,"average_price_per_litre":null},"expenses":[],"totals":{"fuel":0,"service":0,"other":0,"all":0,"per_km":null}}"#
        let detail = try JSONDecoder.ridelog.decode(BikeDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.bike.id, 7)
        XCTAssertNil(detail.bike.year)
        XCTAssertNil(detail.fuel.averageLPer100km)
        XCTAssertNil(detail.totals.perKm)
    }
}

final class GarageLogicTests: XCTestCase {
    private func status(_ state: String, km: Double? = nil, days: Int? = nil, limited: String? = nil) -> ServiceStatus {
        ServiceStatus(state: state, dueKm: nil, dueDate: nil, remainingKm: km, remainingDays: days, limitedBy: limited)
    }

    func testOverdueSaysByHowMuch() {
        XCTAssertEqual(GarageLogic.dueText(status("overdue", km: -200.4, days: 100)), "Overdue by 200 km")
        XCTAssertEqual(GarageLogic.dueText(status("overdue", km: 3000, days: -12)), "Overdue by 12 days")
        XCTAssertEqual(GarageLogic.dueText(status("overdue", km: -50, days: -1)), "Overdue by 50 km and 1 day")
    }

    func testTheTighterIntervalIsTheHeadline() {
        XCTAssertEqual(GarageLogic.dueText(status("ok", km: 5139.3, days: 242, limited: "date")), "in about 8 months")
        XCTAssertEqual(GarageLogic.dueText(status("soon", km: 480.2, days: 200, limited: "km")), "480 km left")
        XCTAssertEqual(GarageLogic.dueDetail(status("soon", km: 480.2, days: 200, limited: "km")), "in about 6 months")
        XCTAssertEqual(GarageLogic.dueDetail(status("ok", km: 5139.3, days: 242, limited: "date")), "5139 km left")
    }

    func testOnlyOneIntervalHasNoDetailLine() {
        XCTAssertEqual(GarageLogic.dueText(status("ok", km: 1200, days: nil, limited: "km")), "1200 km left")
        XCTAssertNil(GarageLogic.dueDetail(status("ok", km: 1200, days: nil, limited: "km")))
        XCTAssertEqual(GarageLogic.dueText(status("soon", km: nil, days: 20, limited: "date")), "in 20 days")
    }

    func testNeverDone() {
        XCTAssertEqual(GarageLogic.dueText(status("never_done")), "Not done yet")
        XCTAssertNil(GarageLogic.dueDetail(status("never_done")))
        XCTAssertEqual(status("something new").serviceState, .neverDone)
    }

    func testDaysInWords() {
        XCTAssertEqual(GarageLogic.daysText(0), "today")
        XCTAssertEqual(GarageLogic.daysText(1), "tomorrow")
        XCTAssertEqual(GarageLogic.daysText(30), "in 30 days")
        XCTAssertEqual(GarageLogic.daysText(90), "in 90 days")
        XCTAssertEqual(GarageLogic.daysText(180), "in about 6 months")
    }

    func testNumbersAreFormattedWithoutLocaleSurprises() {
        XCTAssertEqual(GarageLogic.money(47.1), "47.10")
        XCTAssertEqual(GarageLogic.consumption(4.44), "4.4 L/100 km")
        XCTAssertEqual(GarageLogic.odometer(10360.7), "10361 km")
    }

    func testIntervalTextForOneOrBothIntervals() throws {
        let both = try JSONDecoder.ridelog.decode(ServiceItem.self, from: Data(#"{"id":1,"name":"a","interval_km":6000,"interval_months":1,"last_done_date":null,"last_done_km":null,"status":{"state":"never_done","due_km":null,"due_date":null,"remaining_km":null,"remaining_days":null,"limited_by":null}}"#.utf8))
        XCTAssertEqual(both.intervalText, "every 6000 km or 1 month")
        let months = try JSONDecoder.ridelog.decode(ServiceItem.self, from: Data(#"{"id":2,"name":"b","interval_km":null,"interval_months":24,"last_done_date":null,"last_done_km":null,"status":{"state":"never_done","due_km":null,"due_date":null,"remaining_km":null,"remaining_days":null,"limited_by":null}}"#.utf8))
        XCTAssertEqual(months.intervalText, "every 24 months")
    }

    func testRemindersComeBackOnlyAfterThreeDays() {
        let now = Date(timeIntervalSince1970: 1_790_586_900)
        XCTAssertFalse(ReminderPolicy.shouldNotify(due: 0, lastNotified: nil, now: now))
        XCTAssertTrue(ReminderPolicy.shouldNotify(due: 2, lastNotified: nil, now: now))
        XCTAssertFalse(ReminderPolicy.shouldNotify(due: 2, lastNotified: now.addingTimeInterval(-2 * 86_400), now: now))
        XCTAssertTrue(ReminderPolicy.shouldNotify(due: 2, lastNotified: now.addingTimeInterval(-3 * 86_400), now: now))
    }

    func testReminderWording() {
        XCTAssertEqual(ReminderPolicy.text(overdue: 1, soon: 0), "1 service is overdue.")
        XCTAssertEqual(ReminderPolicy.text(overdue: 2, soon: 1), "2 services are overdue, 1 is due soon.")
        XCTAssertEqual(ReminderPolicy.text(overdue: 0, soon: 3), "3 are due soon.")
    }
}
