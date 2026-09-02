# rfid/reader.py

from mfrc522 import MFRC522
import RPi.GPIO as GPIO
import time

AUTH_KEY = [0x4A, 0x1E, 0xD9, 0x40, 0xF4, 0x4B]  # CSU card sector key
SECTOR = 1  # Sector containing CSU ID

class RFIDReader:
    def __init__(self):
        GPIO.setwarnings(False)
        GPIO.setmode(GPIO.BOARD)
        self.reader = MFRC522()

    def uid_to_number(self, uid):
        num = 0
        for byte in uid:
            num = num * 256 + byte
        return num

    def read_card(self):
        (status, uid) = self.reader.MFRC522_Request(self.reader.PICC_REQIDL)
        if status != self.reader.MI_OK:
            return None

        (status, uid) = self.reader.MFRC522_Anticoll()
        if status != self.reader.MI_OK:
            return None

        self.reader.MFRC522_SelectTag(uid)
        block_addr = SECTOR * 4

        status = self.reader.MFRC522_Auth(self.reader.PICC_AUTHENT1A, block_addr, AUTH_KEY, uid)
        if status != self.reader.MI_OK:
            print("[RFID] Authentication failed")
            return None

        data = self.reader.MFRC522_Read(block_addr)
        self.reader.MFRC522_StopCrypto1()

        if not data:
            print("[RFID] Failed to read data block")
            return None

        trimmed = data[3:8]
        csu_id = int.from_bytes(trimmed, byteorder='big') // 10
        uid_num = self.uid_to_number(uid)

        print(f"[RFID] Card scanned ? UID: {uid_num}, CSU ID: {csu_id}")
        return uid_num, csu_id

    def cleanup(self):
        GPIO.cleanup()
