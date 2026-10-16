// 공용 기능 (Firebase): 공용 캐릭터 정보 + 암호 게시판 + 관리자.
// firebase-config.js 가 비어 있으면 아무것도 하지 않고, 툴은 이 기기 저장만으로 동작함.
"use strict";
window.ONLINE = (() => {
  const V = '10.14.1';
  const PBKDF2_ROUNDS = 150000;
  const O = {
    enabled: !!window.FIREBASE_CONFIG, ready: false, error: '', uid: '', isAdmin: false,
    shared: loadCache(), sharedLoaded: false, listeners: [],
  };
  let fs = null, db = null;

  function loadCache() { try { return JSON.parse(localStorage.getItem('gs-shared-cache') || 'null') || {}; } catch (e) { return {}; } }
  function saveCache() { try { localStorage.setItem('gs-shared-cache', JSON.stringify(O.shared)); } catch (e) {} }
  const emit = () => O.listeners.forEach(f => { try { f(); } catch (e) { console.error(e); } });
  O.onChange = f => O.listeners.push(f);

  /* ---------- 접속 ---------- */
  O.start = async () => {
    if (!O.enabled) return;
    try {
      const appM = await import(`https://www.gstatic.com/firebasejs/${V}/firebase-app.js`);
      const authM = await import(`https://www.gstatic.com/firebasejs/${V}/firebase-auth.js`);
      fs = await import(`https://www.gstatic.com/firebasejs/${V}/firebase-firestore.js`);
      const app = appM.initializeApp(window.FIREBASE_CONFIG);
      const auth = authM.getAuth(app);
      db = fs.getFirestore(app);
      // 보이지 않는 자동 로그인: 기기(브라우저)마다 고유 ID가 생김
      await new Promise((res, rej) => {
        const off = authM.onAuthStateChanged(auth, u => { if (u) { O.uid = u.uid; off(); res(); } });
        authM.signInAnonymously(auth).catch(rej);
      });
      // 공용 캐릭터 정보는 실시간으로 받음
      fs.onSnapshot(fs.doc(db, 'shared', 'chars'), snap => {
        O.shared = (snap.exists() && snap.data().data) || {};
        O.sharedLoaded = true; saveCache(); emit();
      }, e => { O.error = e.message; emit(); });
      try { O.isAdmin = (await fs.getDoc(fs.doc(db, 'admins', O.uid))).exists(); } catch (e) {}
      O.ready = true; emit();
    } catch (e) {
      console.error(e); O.error = e.message || String(e); emit();
    }
  };
  const need = () => { if (!O.ready) throw new Error(O.enabled ? '공용 서버에 아직 연결되지 않았어요. 잠시 후 다시 해 주세요.' : '공용 기능이 설정되지 않았어요.'); };

  /* ---------- 공용 캐릭터 정보 ---------- */
  // entry: 그 캐릭터의 공용 값 전체 (null 이면 공용 값 지우기). baseRev: 편집을 시작할 때의 버전
  O.saveChar = async (name, entry, baseRev, by) => {
    need();
    const ref = fs.doc(db, 'shared', 'chars');
    const histRef = fs.doc(fs.collection(db, 'charHistory'));
    return fs.runTransaction(db, async tx => {
      const snap = await tx.get(ref);
      const data = (snap.exists() && snap.data().data) || {};
      const cur = data[name] || null;
      if ((cur ? cur.rev || 0 : 0) !== (baseRev || 0)) return { conflict: true, current: cur };
      const next = Object.assign({}, data);
      if (entry) next[name] = Object.assign({}, entry, { rev: (baseRev || 0) + 1, by, at: Date.now() });
      else delete next[name];
      tx.set(ref, { data: next, updatedAt: Date.now(), by });
      tx.set(histRef, { name, before: JSON.stringify(cur), after: JSON.stringify(next[name] || null), by, uid: O.uid, at: Date.now() });
      return { ok: true };
    });
  };
  // 여러 캐릭터를 한꺼번에 (이 기기에서 고친 내용을 공용으로 올릴 때)
  O.saveChars = async (entries, by) => {
    need();
    const ref = fs.doc(db, 'shared', 'chars');
    return fs.runTransaction(db, async tx => {
      const snap = await tx.get(ref);
      const data = Object.assign({}, (snap.exists() && snap.data().data) || {});
      for (const [name, e] of Object.entries(entries)) {
        const cur = data[name] || null;
        data[name] = Object.assign({}, cur || {}, e, { rev: ((cur && cur.rev) || 0) + 1, by, at: Date.now() });
        tx.set(fs.doc(fs.collection(db, 'charHistory')), { name, before: JSON.stringify(cur), after: JSON.stringify(data[name]), by, uid: O.uid, at: Date.now() });
      }
      tx.set(ref, { data, updatedAt: Date.now(), by });
      return Object.keys(entries).length;
    });
  };
  O.history = async name => {
    need();
    const q = fs.query(fs.collection(db, 'charHistory'), fs.where('name', '==', name));
    const snap = await fs.getDocs(q);
    return snap.docs.map(d => Object.assign({ id: d.id }, d.data())).sort((a, b) => b.at - a.at).slice(0, 30);
  };

  /* ---------- 암호화 (브라우저 안에서만) ---------- */
  const te = new TextEncoder(), td = new TextDecoder();
  const toB64 = bytes => { let s = ''; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
  const fromB64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
  const hex = bytes => [...bytes].map(x => x.toString(16).padStart(2, '0')).join('');
  // 글 암호 → 암호화 열쇠(앞 32바이트) + 서버 확인값(뒤 32바이트). 확인값으로는 내용을 풀 수 없음
  async function derive(password, saltB64) {
    const base = await crypto.subtle.importKey('raw', te.encode(password), 'PBKDF2', false, ['deriveBits']);
    const bits = new Uint8Array(await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: fromB64(saltB64), iterations: PBKDF2_ROUNDS }, base, 512));
    const key = await crypto.subtle.importKey('raw', bits.slice(0, 32), 'AES-GCM', false, ['encrypt', 'decrypt']);
    return { key, proof: hex(bits.slice(32)) };
  }
  async function encrypt(key, obj) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, te.encode(JSON.stringify(obj))));
    return { iv: toB64(iv), ct: toB64(ct) };
  }
  async function decrypt(key, ivB64, ctB64) {
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: fromB64(ivB64) }, key, fromB64(ctB64));
    return JSON.parse(td.decode(pt));
  }
  O.sha256hex = async s => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', te.encode(s))));

  // 이 기기에 기억해 둔 글 암호
  const pwMap = () => { try { return JSON.parse(localStorage.getItem('gs-post-pw') || '{}'); } catch (e) { return {}; } };
  O.rememberPw = (id, pw) => { const m = pwMap(); m[id] = pw; try { localStorage.setItem('gs-post-pw', JSON.stringify(m)); } catch (e) {} };
  O.forgetPw = id => { const m = pwMap(); delete m[id]; try { localStorage.setItem('gs-post-pw', JSON.stringify(m)); } catch (e) {} };
  O.knownPw = id => pwMap()[id] || '';

  /* ---------- 게시판 ---------- */
  O.listPosts = async () => {
    need();
    const snap = await fs.getDocs(fs.query(fs.collection(db, 'posts'), fs.orderBy('updatedAt', 'desc'), fs.limit(100)));
    return snap.docs.map(d => { const x = d.data(); return { id: d.id, title: x.title, author: x.author, boss: x.boss, season: x.season, createdAt: x.createdAt, updatedAt: x.updatedAt, size: (x.ct || '').length }; });
  };
  // 암호가 틀리면 '암호가 맞지 않아요' 오류
  O.openPost = async (id, password) => {
    need();
    const snap = await fs.getDoc(fs.doc(db, 'posts', id));
    if (!snap.exists()) throw new Error('지워진 글이에요.');
    const x = snap.data();
    const { key } = await derive(password, x.salt);
    let content;
    try { content = await decrypt(key, x.iv, x.ct); } catch (e) { throw new Error('암호가 맞지 않아요.'); }
    O.rememberPw(id, password);
    return { meta: Object.assign({ id }, x, { ct: undefined }), content };
  };
  // 이 기기가 그 글을 고칠 수 있게 등록 (암호 확인값이 맞아야 서버가 허락함)
  async function ensureGrant(id, proof) {
    const g = fs.doc(db, 'grants', id + '_' + O.uid);
    try { if ((await fs.getDoc(g)).exists()) return; } catch (e) {}
    await fs.setDoc(g, { post: id, uid: O.uid, proof });
  }
  // postId 가 있으면 그 글을 고치고, 없으면 새 글
  O.publish = async ({ postId, title, author, password, boss, season, content }) => {
    need();
    const now = Date.now();
    if (postId) {
      const ref = fs.doc(db, 'posts', postId);
      const snap = await fs.getDoc(ref);
      if (!snap.exists()) throw new Error('원래 글이 지워져서 고칠 수 없어요. 새 글로 올려 주세요.');
      const x = snap.data();
      const { key, proof } = await derive(password, x.salt);
      try { await decrypt(key, x.iv, x.ct); } catch (e) { throw new Error('이 글의 암호가 아니에요.'); }
      if (!O.isAdmin) await ensureGrant(postId, proof);
      const { iv, ct } = await encrypt(key, content);
      await fs.setDoc(ref, { title, author, boss, season, salt: x.salt, iv, ct, createdAt: x.createdAt, updatedAt: now });
      O.rememberPw(postId, password);
      return postId;
    }
    const ref = fs.doc(fs.collection(db, 'posts'));
    const salt = toB64(crypto.getRandomValues(new Uint8Array(16)));
    const { key, proof } = await derive(password, salt);
    const { iv, ct } = await encrypt(key, content);
    const b = fs.writeBatch(db);
    b.set(ref, { title, author, boss, season, salt, iv, ct, createdAt: now, updatedAt: now });
    b.set(fs.doc(db, 'postKeys', ref.id), { proof });
    b.set(fs.doc(db, 'grants', ref.id + '_' + O.uid), { post: ref.id, uid: O.uid, proof });
    await b.commit();
    O.rememberPw(ref.id, password);
    return ref.id;
  };
  // 관리자는 암호 없이 지울 수 있음
  O.deletePost = async (id, password) => {
    need();
    if (!O.isAdmin) {
      const snap = await fs.getDoc(fs.doc(db, 'posts', id));
      if (!snap.exists()) return;
      const x = snap.data();
      const { key, proof } = await derive(password, x.salt);
      try { await decrypt(key, x.iv, x.ct); } catch (e) { throw new Error('암호가 맞지 않아요.'); }
      await ensureGrant(id, proof);
    }
    const b = fs.writeBatch(db);
    b.delete(fs.doc(db, 'postKeys', id));
    b.delete(fs.doc(db, 'posts', id));
    await b.commit();
    O.forgetPw(id);
  };

  /* ---------- 관리자 ---------- */
  // 처음 한 번: 관리자 코드 정하기 → 이 기기를 관리자로 등록
  O.adminSetup = async code => {
    need();
    const h = await O.sha256hex('gs-admin:' + code);
    await fs.setDoc(fs.doc(db, 'secret', 'admin'), { code: h });
    await fs.setDoc(fs.doc(db, 'admins', O.uid), { code: h });
    O.isAdmin = true; emit();
  };
  O.adminLogin = async code => {
    need();
    const h = await O.sha256hex('gs-admin:' + code);
    try { await fs.setDoc(fs.doc(db, 'admins', O.uid), { code: h }); }
    catch (e) { throw new Error('관리자 코드가 맞지 않아요.'); }
    O.isAdmin = true; emit();
  };
  // 관리자 코드 바꾸기 (관리자만). revokeOthers 면 이 기기 말고 다른 관리자 기기는 모두 해제
  O.adminChange = async (newCode, revokeOthers) => {
    need();
    if (!O.isAdmin) throw new Error('관리자만 바꿀 수 있어요.');
    const h = await O.sha256hex('gs-admin:' + newCode);
    await fs.setDoc(fs.doc(db, 'secret', 'admin'), { code: h });
    let removed = 0;
    if (revokeOthers) {
      const snap = await fs.getDocs(fs.collection(db, 'admins'));
      for (const d of snap.docs) if (d.id !== O.uid) { await fs.deleteDoc(d.ref); removed++; }
    }
    return removed;
  };
  O.blockDevice = async uid => { need(); await fs.setDoc(fs.doc(db, 'blocked', uid), { at: Date.now() }); };
  O.unblockDevice = async uid => { need(); await fs.deleteDoc(fs.doc(db, 'blocked', uid)); };
  O.listBlocked = async () => { need(); return (await fs.getDocs(fs.collection(db, 'blocked'))).docs.map(d => d.id); };
  return O;
})();
