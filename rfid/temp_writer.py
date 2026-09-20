"""Program a temporary card for a job from temp_card_claim_job() (contract: dashboard PI_ACCESS_CHECK.md, section 3)."""
import logging
from rfid.card_io import (
    CardLost, FACTORY, ACCESS, uid_hex, data_block, trailer_block, make_trailer,
)

logger = logging.getLogger("temp_writer")


def program_card(io, job):
    """Write the job's secret and trailer to the card on the reader. Returns (ok, detail).

    Checks, in order: the card on the reader is the job's card; its sector opens with one of the job's
    previous keys (newest first) or the factory key; then secret block, trailer, read back with the new key.
    Never touches sectors 0 and 1, and never writes any access bytes but FF 07 80 69.
    """
    try:
        sector = int(job["sector"])
        sector_key = list(job["sector_key"])
        secret = list(job["secret"])
        previous = [list(k) for k in (job["previous_keys"] or [])]
        want_uid = str(job["card_uid"]).strip().upper()
        if not 2 <= sector <= 15:
            return False, f"refusing sector {sector}: sectors 0 and 1 hold the CSU data"
        if len(sector_key) != 6 or len(secret) != 16:
            return False, "job has a malformed key or secret"
        trailer = make_trailer(sector_key)
        blk, tb = data_block(sector), trailer_block(sector)
        assert blk >= 8 and trailer[6:10] == ACCESS

        # 1. The card on the reader right now must be the card the dashboard asked for.
        uid = io.select(wait=3)
        if uid is None:
            return False, "card not on the reader"
        if uid_hex(uid) != want_uid:
            return False, f"card changed (reader has {uid_hex(uid)}, job is for {want_uid})"

        # 2. Which key opens the sector: an earlier issue's key (a card that failed half-way, or is being
        #    reissued) or the factory key. Sectors 0 and 1 are only reported, never needed.
        blank = io.is_blank()
        open_key = None
        for key in previous + [FACTORY]:
            io.fresh()
            if io.auth(blk, key):
                open_key = key
                break
        if open_key is None:
            return False, "card changed or not writable"
        logger.info(f"[TEMP] Programming {want_uid} sector {sector}: blank={blank}, "
                    f"opened with {'factory key' if open_key == FACTORY else 'a previous key'}")

        # 3. Secret first, then the trailer, in one authenticated session (as bench-tested).
        io.fresh()
        if not io.auth(blk, open_key):
            return False, "lost access to the sector before writing"
        io.write(blk, secret)
        io.write(tb, trailer)

        # 4. Prove it: the new key must open the sector and the secret must read back.
        io.fresh()
        if not io.auth(blk, sector_key):
            return False, "new key was not accepted after writing"
        got = io.read(blk)
        io.r.MFRC522_StopCrypto1()
        if list(got or []) != secret:
            return False, "secret did not read back"
        return True, None
    except CardLost:
        return False, "card left the reader during programming"
    except Exception as e:
        logger.exception("[TEMP] Programming failed")
        return False, f"reader error: {type(e).__name__}: {e}"
