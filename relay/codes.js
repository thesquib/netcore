// Room codes: 4 of 20 consonants (no vowels, so no words; no I/O to confuse with 1/0).
export const ALPHABET = 'BCDFGHJKLMNPQRSTVWXZ';

export function randomCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(4));
  return [...bytes].map(b => ALPHABET[b % ALPHABET.length]).join('');
}

// Upper-cases and strips spaces; null unless it's exactly 4 alphabet letters.
export function normalise(s) {
  const code = String(s).toUpperCase().replace(/\s+/g, '');
  return /^[BCDFGHJKLMNPQRSTVWXZ]{4}$/.test(code) ? code : null;
}
