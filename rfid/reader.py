from mfrc522 import MFRC522
import RPi.GPIO as GPIO
import time
import logging
from collections import namedtuple

logger = logging.getLogger("rfid")

AUTH_KEY = [0x4A, 0x1E, 0xD9, 0x40, 0xF4, 0x4B]  # CSU card sector key
SECTOR = 1  # Sector containing CSU ID

def uid_hex(uid):
    """The card UID as the server stores it: the first 4 bytes, upper-case hex."""
    return "".join("%02X" % b for b in uid[:4])


class CardScan(namedtuple("CardScan", "uid uid_hex uid_num csu_id")):
    __slots__ = ()


class RFIDReader:
    def __init__(self, leds=None):
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BOARD)
        self.leds = leds
        self.reader = MFRC522(pin_rst=22)

    def uid_to_number(self, uid):
        num = 0
        for byte in uid:
            num = num * 256 + byte
        return num

    def read_card_ex(self):
        """Detect a card and return a CardScan, or None if nothing is on the reader.

        `csu_id` is None when the card is present but is not a student card (sector 1 does not open
        with the CSU key): a blank, a temporary card or anything else. The UID is still returned so
        the caller can look the card up.
        """
        (status, uid) = self.reader.MFRC522_Request(self.reader.PICC_REQIDL)
        if status != self.reader.MI_OK:
            return None

        (status, uid) = self.reader.MFRC522_Anticoll()
        if status != self.reader.MI_OK:
            return None

        # Before the auth attempt, so a rejected card still lights D1 and
        # "the reader never saw it" is distinguishable from "it was refused".
        if self.leds:
            self.leds.reader_blink()

        uid_num = self.uid_to_number(uid)
        scan = CardScan(list(uid), uid_hex(uid), uid_num, None)

        self.reader.MFRC522_SelectTag(uid)
        block_addr = SECTOR * 4

        status = self.reader.MFRC522_Auth(self.reader.PICC_AUTHENT1A, block_addr, AUTH_KEY, uid)
        if status != self.reader.MI_OK:
            # Every poll of a resting non-student card lands here, so this is not a warning.
            logger.debug("[RFID] CSU authentication failed (not a student card)")
            return scan

        data = self.reader.MFRC522_Read(block_addr)
        self.reader.MFRC522_StopCrypto1()

        if not data:
            logger.warning("[RFID] Failed to read data block")
            return scan

        trimmed = data[3:8]
        csu_id = int.from_bytes(trimmed, byteorder='big') // 10

        logger.info(f"[RFID] Card scanned - UID: {uid_num}, CSU ID: {csu_id}")
        return CardScan(scan.uid, scan.uid_hex, uid_num, csu_id)

    def read_card(self):
        """Student cards only: (uid_num, csu_id), or None for no card / not a student card."""
        scan = self.read_card_ex()
        if scan is None or scan.csu_id is None:
            return None
        return scan.uid_num, scan.csu_id

    def cleanup(self):
        GPIO.cleanup()
