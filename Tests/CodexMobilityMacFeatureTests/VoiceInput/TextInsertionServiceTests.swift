import XCTest
@testable import CodexMobilityMacFeature

final class TextInsertionServiceTests: XCTestCase {
    func testReceiptIgnoresProviderReadBeforeItIsArmed() async {
        let receipt = PasteboardReadReceipt()

        receipt.markStringRead()
        receipt.arm()

        let confirmed = await receipt.waitForStringRead(
            timeout: .milliseconds(20)
        )
        XCTAssertFalse(confirmed)
    }

    func testArmedReceiptConfirmsProviderRead() async {
        let receipt = PasteboardReadReceipt()
        receipt.arm()

        receipt.markStringRead()
        receipt.markStringRead()

        let confirmed = await receipt.waitForStringRead(
            timeout: .milliseconds(20)
        )
        XCTAssertTrue(confirmed)
    }

    func testDeliveryRequiresFocusedTargetAndChangedObservableRange() {
        let captured = TextSelectionRangeSnapshot(location: 4, length: 0)
        let delivered = TextSelectionRangeSnapshot(location: 9, length: 0)

        XCTAssertTrue(
            PasteboardDeliveryEvidence(
                targetStillFocused: true,
                capturedRange: captured,
                deliveredRange: delivered,
                insertedUTF16Count: 5
            ).confirmsTargetDelivery
        )
        XCTAssertFalse(
            PasteboardDeliveryEvidence(
                targetStillFocused: false,
                capturedRange: captured,
                deliveredRange: delivered,
                insertedUTF16Count: 5
            ).confirmsTargetDelivery
        )
        XCTAssertFalse(
            PasteboardDeliveryEvidence(
                targetStillFocused: true,
                capturedRange: nil,
                deliveredRange: delivered,
                insertedUTF16Count: 5
            ).confirmsTargetDelivery
        )
        XCTAssertFalse(
            PasteboardDeliveryEvidence(
                targetStillFocused: true,
                capturedRange: captured,
                deliveredRange: nil,
                insertedUTF16Count: 5
            ).confirmsTargetDelivery
        )
        XCTAssertFalse(
            PasteboardDeliveryEvidence(
                targetStillFocused: true,
                capturedRange: captured,
                deliveredRange: captured,
                insertedUTF16Count: 5
            ).confirmsTargetDelivery
        )
    }

    func testStandardDeliveryPolicyUsesBoundedConfirmationAndShortSettle() {
        XCTAssertEqual(
            PasteboardDeliveryPolicy.standard.confirmationTimeout,
            .milliseconds(1_500)
        )
        XCTAssertEqual(
            PasteboardDeliveryPolicy.standard.postReadSettleDelay,
            .milliseconds(80)
        )
    }
}
