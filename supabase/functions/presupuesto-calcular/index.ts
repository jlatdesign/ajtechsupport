// @ts-nocheck
// =====================================================================
//  Edge Function "presupuesto-calcular" — calcula un presupuesto guardado
//  con las tarifas y márgenes privados, en el servidor.
//
//  El operador NUNCA recibe tarifa, salario ni márgenes: solo horas y el
//  total que el admin ya liberó. Solo recibe el id del presupuesto: los
//  datos y precios se leen de la base, no de lo que mande el navegador.
//
//  Cómo instalarla (una sola vez):
//   Supabase → Edge Functions → Deploy a new function → Via Editor
//   Nombre: presupuesto-calcular → borra lo que trae, pega TODO este archivo → Deploy
//
//  ⚠ El bloque MOTOR es copia exacta del cálculo de inventario/index.html.
//  Si cambias el cálculo allá, copia el cambio aquí y publica otra vez.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const t = (k) => k;   // el servidor no necesita los textos
var PERM = {};

// ---------- MOTOR (copia de inventario/index.html) ----------
const jObj = v => { if (typeof v === 'string'){ try{ v = JSON.parse(v); }catch(e){ v = {}; } } return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; };
const jArr = v => { if (typeof v === 'string'){ try{ v = JSON.parse(v); }catch(e){ v = []; } } return Array.isArray(v) ? v : []; };
const PRESU_DEF = {
  empresa: { nombre: 'AJ Tech Support', direccion: '', telefono: '', email: '', web: 'ajtechsupport.net', licencia: '' }, terminos: '',
  tarifa: 0, salario: 0, cargas: 0, extra: 0, horas_dia: 8, eficiencia: 0.85, margen_mat: 0, margen_eq: 0, impuesto: 7, contingencia: 0, validez: 30,
  t: { drop: 0.75, pies_hora: 80, conduit_pies_hora: 30, prueba: 0.1, ap: 0.5, ap_cfg: 0.15, cam_int: 0.75, cam_ext: 1.25, cam_cfg: 0.25,
       rack: 3, patch: 1, switch: 1.5, nvr: 2, fibra: 3, fibra_term: 1.5, survey: 2, pm: 8 },
  f_alt: { 10: 1, 14: 1.15, 20: 1.25, 30: 1.4, 99: 1.7 },
  f_techo: { falso: 1, drywall: 1.35, abierto: 1.1, concreto: 1.5 },
  f_dif: { facil: 0.9, normal: 1, dificil: 1.3 },
  pp: { drop_pared: 0, drop_techo: 0, cam_int: 0, cam_ext: 0, switch: 0, nvr: 0, rack: 0, fibra: 0 },
  recargo_alt: { 14: 0, 20: 0, 30: 0, 99: 0 },
  mat: { cat6: 0, cat6p: 0, cat6a: 0, jack: 0, placa: 0, caja: 0, patch24: 0, cordon: 0, jhook: 0, emt: 0, fibra_pie: 0, fibra_term: 0, rack: 0, misc: 0, desperdicio: 10 },
  renta: { tijera: 0, boom: 0 },
  equipos: [
    { m: 'U7 Pro', c: 'ap' }, { m: 'U7 Pro Max', c: 'ap' }, { m: 'U7 Lite', c: 'ap' }, { m: 'U7 Long-Range', c: 'ap' }, { m: 'U7 Outdoor', c: 'ap' },
    { m: 'U6+', c: 'ap' }, { m: 'U6 Mesh', c: 'ap' },
    { m: 'G5 Bullet', c: 'cam' }, { m: 'G5 Turret Ultra', c: 'cam' }, { m: 'G5 Dome', c: 'cam' }, { m: 'G5 Pro', c: 'cam' }, { m: 'AI Pro', c: 'cam' },
    { m: 'USW Lite 16 PoE', c: 'sw' }, { m: 'USW Pro Max 24 PoE', c: 'sw' }, { m: 'USW Pro Max 48 PoE', c: 'sw' }, { m: 'USW Enterprise 24 PoE', c: 'sw' },
    { m: 'UDM Pro Max', c: 'gw' }, { m: 'UCG Fiber', c: 'gw' }, { m: 'UNVR', c: 'nvr' }, { m: 'UNVR Pro', c: 'nvr' }, { m: 'HDD 8TB Surveillance', c: 'otro' },
    { m: 'UPS 1500VA rack', c: 'otro' }, { m: 'Rack 12U pared', c: 'otro' } ] };
const PR_TIPOS = ['oficina', 'almacen', 'mixto', 'retail', 'exterior'];
const PR_TECHOS = ['falso', 'drywall', 'abierto', 'concreto'];
const PR_PUNTOS = [['drop_pared', '🔌'], ['drop_techo', '📶'], ['cam_int', '📷'], ['cam_ext', '🎥'], ['switch', '🔀'], ['nvr', '📹'], ['rack', '🗄️'], ['fibra', '🧵']];
const PR_ESTADOS = ['borrador', 'enviado', 'aprobado', 'perdido', 'completado'];
let presus = [], presuOK = true, PRC = null, PRCP = null, PR = null, PRES = { open: false, edit: false, q: '', estado: '' };
// 🔒 Lo privado (solo admin) vive en presu_config_priv y presupuesto_priv. Si cambias estas listas, cambia también supabase-precios-priv.sql.
const PR_PRIV_TOP = ['tarifa', 'salario', 'cargas', 'extra', 'margen_mat', 'margen_eq', 'contingencia'], PR_PRIV_OBJ = ['pp', 'recargo_alt', 'renta'];
const PR_PRIV_TT = ['tarifa', 'salario', 'nivel', 'servidor', 'sitio', 'backup_tb', 'm365', 'hosting', 'dominio', 'mant', 'soporte', 'red', 'impresora'];
const prJunta = (a, b) => { const r = { ...a }, esO = v => v && typeof v === 'object' && !Array.isArray(v); Object.keys(b || {}).forEach(k => { r[k] = esO(r[k]) && esO(b[k]) ? prJunta(r[k], b[k]) : b[k]; }); return r; };
const prConfArmar = (pub, priv) => { const { equipos_p, ...resto } = jObj(priv), c = prJunta(jObj(pub), resto), d = PRESU_DEF, m = (a, b) => ({ ...a, ...jObj(b) }), ep = jObj(equipos_p);
  return { ...d, ...c, t: m(d.t, c.t), f_alt: m(d.f_alt, c.f_alt), f_techo: m(d.f_techo, c.f_techo), f_dif: m(d.f_dif, c.f_dif), pp: m(d.pp, c.pp),
    recargo_alt: m(d.recargo_alt, c.recargo_alt), mat: m(d.mat, c.mat), renta: m(d.renta, c.renta), empresa: m(d.empresa, c.empresa),
    equipos: (Array.isArray(c.equipos) && c.equipos.length ? c.equipos : d.equipos).map(e => ({ ...e, p: n0(ep[e.m]) || n0(e.p) })) }; };
const prConf = () => prConfArmar(PRC?.datos, PRCP?.datos);
// Parte la configuración del formulario ⚙ en lo que ve el operador y lo que solo ve el admin
const prSepararConf = datos => { const pub = JSON.parse(JSON.stringify(jObj(datos))), priv = {};
  PR_PRIV_TOP.concat(PR_PRIV_OBJ).forEach(k => { if (pub[k] !== undefined){ priv[k] = pub[k]; delete pub[k]; } });
  if (pub.mat){ const { desperdicio, ...resto } = pub.mat; priv.mat = resto; pub.mat = desperdicio === undefined ? {} : { desperdicio }; }   // el desperdicio cambia cantidades, no es un precio
  if (Array.isArray(pub.equipos)){ priv.equipos_p = {}; pub.equipos = pub.equipos.map(({ p, ...e }) => { if (e.m && p != null) priv.equipos_p[e.m] = p; return e; }); }
  if (pub.tt){ priv.tt = {}; Object.keys(pub.tt).forEach(tp => { const T = pub.tt[tp], v = {}; PR_PRIV_TT.forEach(k => { if (T[k] !== undefined){ v[k] = T[k]; delete T[k]; } });
    if (T.items){ v.items = {}; Object.keys(T.items).forEach(i => { if (T.items[i].f !== undefined){ v.items[i] = { f: T.items[i].f }; delete T.items[i].f; } }); } priv.tt[tp] = v; }); }
  return { pub, priv }; };
// Parte un presupuesto: tarifa, salario, % de ganancia y precios por línea van a presupuesto_priv
const prSepararDatos = d => { const sinP = a => jArr(a).map(({ p, ...x }) => x), conP = (a, k) => jArr(a).filter(x => n0(x.p)).map(x => ({ [k]: x[k], p: x.p }));
  const { tarifa, salario, meta, ...pub } = d; ['equipos', 'mat_extra', 'partidas'].forEach(k => { if (pub[k] !== undefined) pub[k] = sinP(pub[k]); });
  return { pub, priv: { tarifa, salario, meta, precios: { eq: conP(d.equipos, 'm'), mat: conP(d.mat_extra, 'd'), par: conP(d.partidas, 'd') } } }; };
const prPonP = (a, ps, k) => { const r = jArr(ps).slice(); return jArr(a).map(x => { if (n0(x.p)) return x; const i = r.findIndex(y => y[k] === x[k]); return i < 0 ? x : { ...x, p: r.splice(i, 1)[0].p }; }); };
const prUnirDatos = (d, pv) => { const v = jObj(pv), c = jObj(v.precios), r = { ...d }; ['tarifa', 'salario', 'meta'].forEach(k => { if (v[k] != null) r[k] = v[k]; });
  if (d.equipos) r.equipos = prPonP(d.equipos, c.eq, 'm'); if (d.mat_extra) r.mat_extra = prPonP(d.mat_extra, c.mat, 'd'); if (d.partidas) r.partidas = prPonP(d.partidas, c.par, 'd'); return r; };
// Un equipo sin precio (lo agregó un operador) toma el de la lista
const prConPrecios = (d, C) => ({ ...d, equipos: jArr(d.equipos).map(e => n0(e.p) ? e : { ...e, p: C.equipos.find(x => x.m === e.m)?.p ?? e.p }) });
const prTotVer = p => ({ ...jObj(p.totales), ...(PERM.admin ? jObj(p.priv?.totales) : { total: p.total_liberado, mensual: p.mensual_liberado }) });
const prPrivOK = () => { if (PRCP) return true; alert(t('pr_priv_falta')); return false; };
// Lo que le pagas al técnico por hora (costo interno; no sale en el PDF). Se puede cambiar en cada presupuesto.
const prSalarioDef = (C, tp) => n0(tp === 'instalacion' ? C.salario : prTT(C, tp).salario) || n0(C.salario);
const prSalario = (d, C, tp) => n0(d?.salario) || prSalarioDef(C, tp);
const prTarifaDef = (C, tp) => n0(tp === 'instalacion' ? C.tarifa : prTT(C, tp).tarifa);
const prTarifa = (d, C, tp) => n0(d?.tarifa) || prTarifaDef(C, tp);   // tarifa de este presupuesto (o la de ⚙)
// Margen de ganancia %: se suma encima del precio (mano de obra, materiales, equipos, cargos). Va aparte de la tarifa por hora.
// % de ganancia: si lo fijas (d.meta), el precio se ajusta para darte ese % sin tocar la tarifa por hora.
// Si está vacío, se muestra el % automático que sale de la tarifa.
const prMeta = d => { const v = d?.meta; return v != null && v !== '' && n0(v) > 0 && n0(v) < 90 ? n0(v) : null; };
const prAjuste = (base, costo, d) => { const g = prMeta(d); return g == null || !base ? 1 : costo / (1 - g / 100) / base; };
const prCostoMO = (h, d, C, tp) => h * prSalario(d, C, tp) * (1 + n0(C.cargas) / 100);
const escalon = (tabla, v) => { const ks = Object.keys(tabla).map(Number).sort((a, b) => a - b); for (const k of ks) if (v <= k) return tabla[k]; return tabla[ks[ks.length - 1]]; };
const money = v => (v < 0 ? '−' : '') + '$' + Math.abs(Math.round(v)).toLocaleString('en-US');
const n0 = v => +v || 0;
const prVer = () => !PERM.roles || PERM.admin || PERM.rol === 'operador';


/* ---------- Aprender de los trabajos cerrados ---------- */
function prAprendido(sitio, tipo = prTipo(PR?.d)){
  const hechos = presus.filter(p => p.estado === 'completado' && +p.horas_est > 0 && +p.horas_real > 0 && (!PR || p.id !== PR.id) && prTipo(jObj(p.datos)) === tipo);
  // cada trabajo cuenta según su tamaño; un trabajo raro (más del doble o menos de la mitad) no puede mover todo
  const suave = (arr) => { if (!arr.length) return null; const r = arr.reduce((a, p) => a + Math.min(2, Math.max(.5, p.horas_real / p.horas_est)) * p.horas_est, 0) / arr.reduce((a, p) => a + +p.horas_est, 0), n = arr.length;
    return { f: Math.min(1.8, Math.max(.6, (n * r + 3) / (n + 3))), n, r }; };
  const todo = suave(hechos); if (!todo) return { f: 1, n: 0 };
  if (!PR_CAMPO.includes(tipo)) return todo;
  const alt = n0(sitio?.altura), grupo = hechos.filter(p => { const s = jObj(p.datos).sitio || {}; return escalon({ 14: 1, 20: 2, 30: 3, 99: 4 }, n0(s.altura)) === escalon({ 14: 1, 20: 2, 30: 3, 99: 4 }, alt) && (s.tipo || '') === (sitio?.tipo || ''); });
  const g = grupo.length >= 2 ? suave(grupo) : null;
  return g ? { ...g, grupo: true } : todo;
}


/* ---------- Motor de cálculo ---------- */
function prCalcInst(d, C){
  const s = { tipo: 'oficina', area: 0, altura: 10, techo: 'falso', dificultad: 'normal', horario: 'normal', cable: 'cat6', conduit: 0, corrida: '', racks: 1, ...(d.sitio || {}) };
  const q = { ...(d.q || {}) }; PR_PUNTOS.forEach(([k]) => q[k] = n0(q[k])); q.extra_h = n0(q.extra_h); q.red_h = n0(q.red_h);
  const T = C.t, alt = Math.max(6, n0(s.altura) || 10), area = Math.max(0, n0(s.area)), racks = Math.max(1, n0(s.racks) || 1);
  const runs = q.drop_pared + q.drop_techo + q.cam_int + q.cam_ext;
  const corridaAuto = Math.round(Math.min(295, Math.max(30, Math.sqrt(area / racks || 400) * .55 + alt + 15)));
  const corrida = n0(s.corrida) || corridaAuto, cond = Math.min(100, Math.max(0, n0(s.conduit))) / 100;
  const fA = escalon(C.f_alt, alt), fT = C.f_techo[s.techo] ?? 1, fD = C.f_dif[s.dificultad] ?? 1, fS = fA * fT * fD;
  const h = {};
  h.cable = runs * (T.drop + corrida * (1 - cond) / T.pies_hora + corrida * cond / T.conduit_pies_hora + T.prueba) * fS;
  h.montaje = (q.drop_techo * (T.ap + T.ap_cfg) + q.cam_int * (T.cam_int + T.cam_cfg) + q.cam_ext * (T.cam_ext + T.cam_cfg)) * fA * fD;
  const paneles = Math.ceil(runs / 24);
  h.equipos = q.switch * T.switch + q.nvr * T.nvr + q.rack * T.rack + paneles * T.patch + q.fibra * (T.fibra * fA + T.fibra_term) + q.red_h;
  h.survey = runs || q.switch || q.nvr ? T.survey : 0; h.extra = q.extra_h;
  const base = h.cable + h.montaje + h.equipos + h.survey + h.extra; h.pm = base * T.pm / 100;
  const ap = d.aprendido || { f: 1, n: 0 };
  const total = (base + h.pm) * (ap.f || 1);
  // Personas y tiempo
  const lift = alt > 30 ? 'boom' : alt > 20 ? 'tijera' : alt > 14 ? 'escalera_ext' : 'escalera';
  const minP = alt > 14 ? 2 : 1, hd = n0(C.horas_dia) || 8, ef = n0(C.eficiencia) || .85;
  const diasCon = p => total ? Math.ceil(total / (p * hd * ef)) : 0;
  let pers = n0(d.personas); if (!pers){ pers = minP; while (pers < 6 && diasCon(pers) > 10) pers++; }
  const dias = diasCon(pers), semanas = dias / 5;
  // Precio de la mano de obra: por hora y por punto
  const fH = prHorario(s, C).f, tarifa = n0(C.tarifa) * fH;
  const porHora = total * tarifa;
  const recargo = escalon(C.recargo_alt, alt);
  const lineasPunto = PR_PUNTOS.filter(([k]) => q[k]).map(([k]) => ({ k, qty: q[k], p: (n0(C.pp[k]) + (['drop_techo', 'cam_int', 'cam_ext'].includes(k) ? recargo : 0)) * fH }));
  const porPunto = lineasPunto.reduce((a, l) => a + l.qty * l.p, 0) + (q.extra_h + q.red_h) * tarifa;
  const modo = d.modo === 'punto' ? 'punto' : 'hora', mano = modo === 'punto' ? porPunto : porHora;
  // Materiales
  const M = C.mat, pieCable = n0(M[s.cable] ?? M.cat6), pies = Math.ceil(runs * corrida * (1 + n0(M.desperdicio) / 100));
  const mats = [
    ['m_cable', pies, pieCable, 'ft'], ['m_jack', runs, M.jack], ['m_placa', q.drop_pared, M.placa], ['m_caja', q.drop_techo + q.cam_int + q.cam_ext, M.caja],
    ['m_patch', paneles, M.patch24], ['m_cordon', runs * 2, M.cordon], ['m_jhook', s.techo === 'falso' || s.techo === 'abierto' ? Math.ceil(runs * corrida * (1 - cond) / 5 / 8) : 0, M.jhook],
    ['m_emt', Math.ceil(runs * corrida * cond), M.emt, 'ft'], ['m_fibra', q.fibra * Math.max(150, corrida * 2), M.fibra_pie, 'ft'], ['m_fibra_term', q.fibra * 2, M.fibra_term], ['m_rack', q.rack, M.rack]
  ].filter(m => m[1] > 0).map(([k, qty, p, u]) => ({ k, qty, p: n0(p), u: u || 'u', tot: qty * n0(p) }));
  jArr(d.mat_extra).forEach(m => { if (n0(m.qty) && m.d) mats.push({ k: '', d: m.d, qty: n0(m.qty), p: n0(m.p), u: 'u', tot: n0(m.qty) * n0(m.p) }); });
  const matSub = mats.reduce((a, m) => a + m.tot, 0), matMisc = matSub * n0(M.misc) / 100, matCosto = matSub + matMisc, matVenta = matCosto * (1 + n0(C.margen_mat) / 100);
  // Equipos
  const eqs = jArr(d.equipos).filter(e => e.m && n0(e.qty)).map(e => ({ ...e, qty: n0(e.qty), p: n0(e.p), tot: n0(e.qty) * n0(e.p) }));
  const eqCosto = eqs.reduce((a, e) => a + e.tot, 0), eqVenta = eqCosto * (1 + n0(C.margen_eq) / 100);
  // Renta de lift
  const renta = lift === 'tijera' || lift === 'boom' ? Math.max(1, Math.ceil(semanas)) * n0(C.renta[lift]) : 0;
  const conting = (mano + matVenta) * n0(C.contingencia) / 100;
  const costo = prCostoMO(total, d, C, 'instalacion') + matCosto + eqCosto + renta;   // salario × horas + materiales + equipos + renta
  const base$ = mano + matVenta + eqVenta + renta + conting, fm = prAjuste(base$, costo, d), margen$ = base$ * (fm - 1);
  const impuesto = (matVenta + eqVenta) * fm * n0(C.impuesto) / 100;
  const total$ = base$ + margen$ + impuesto;
  return { s, q, runs, corrida, corridaAuto, pies, fA, fT, fD, h, base, total, pers, minP, dias, semanas, lift, tarifa, tarifaBase: C.tarifa, porHora, porPunto, lineasPunto, recargo, modo, mano,
    mats, matSub, matMisc, matCosto, matVenta, eqs, eqCosto, eqVenta, renta, conting, impuesto, total$, costo, ganancia: total$ - impuesto - costo, fm, margen$, ap,
    tablaP: [1, 2, 3, 4, 5, 6].filter(p => p >= minP).map(p => ({ p, dias: diasCon(p) })) };
}


function prHorario(s, C){
  const x = n0(C.extra) || 1, h = s.horario || 'normal';
  const pct = h === 'fuera' ? 100 : h === 'mixto' ? Math.min(100, Math.max(0, s.pct_fuera === '' || s.pct_fuera == null ? 50 : n0(s.pct_fuera))) : 0;
  return { h, pct, x, f: 1 + pct / 100 * (x - 1) };
}

/* ---------- 💰 Tipos de trabajo (cada uno con su forma de calcular) ---------- */
// item: [clave, horas por unidad, cargo por unidad ($), 'fa' = le afecta la altura/techo]
const PR_TT = {
  desmontaje: { salario: 0, tarifa: 0, items: [
    ['cables', .35, 0, 'fa'], ['soportes', .1, 0, 'fa'], ['ap', .3, 0, 'fa'], ['cam', .4, 0, 'fa'], ['acceso', .75, 0], ['tv', .75, 0], ['rack', 2.5, 0], ['rack_eq', .3, 0],
    ['pc', .25, 0], ['monitor', .15, 0], ['impresora', .4, 0], ['telefono', .1, 0], ['placas', .15, 0], ['rec_pc', .05, 0], ['rec_monitor', .05, 0], ['discos', .1, 0], ['viajes', 1, 0],
    ['levantamiento', 2, 0], ['conduit', .02, 0, 'fa'], ['plafones', .1, 0, 'fa'], ['firestop', .5, 0, 'fa'], ['ups_bat', .1, 0], ['isp', 1, 0], ['contenedor', 0, 0], ['reporte', 2, 0]] },
  mudanza: { salario: 0, tarifa: 0, items: [
    ['pc', .75, 0], ['monitor', .2, 0], ['impresora', 1, 0], ['servidor', 2.5, 0], ['rack_red', 6, 0], ['telefono', .25, 0], ['tv', 1, 0], ['otros', .5, 0], ['red_h', 1, 0], ['isp', 2, 0], ['viajes', 1, 0]] },
  reparacion: { salario: 0, tarifa: 0, items: [
    ['diag', .5, 0], ['virus', 1.5, 0], ['os', 2.5, 0], ['datos', 1, 0], ['recuperacion', 1, 0], ['ssd', 1.5, 0], ['pieza', .5, 0], ['pantalla', 1.5, 0], ['limpieza', 1, 0],
    ['imp_mant', 1.5, 0], ['imp_rep', 2, 0], ['imp_cfg', .75, 0], ['servidor', 3, 0], ['red', 1.5, 0], ['correo', 1, 0], ['visitas', .5, 0]] },
  web: { salario: 0, tarifa: 0, base: { landing: 8, corporativo: 12, ecommerce: 30, webapp: 60 }, pagina: 4, idioma: 30, producto: .25, pagos: 8, envios: 6, integracion: 6, revision: 8, pm: 10, qa: 10,
    feat: { contacto: 2, blog: 8, galeria: 3, citas: 12, whatsapp: 1, mapa: 1, newsletter: 3, login: 16, seo: 6, analytics: 2, accesibilidad: 6, branding: 12, copy: 2, migracion: 1 },
    hosting: 0, dominio: 0, mant: 0 },
  software: { salario: 0, tarifa: 0, tam: { S: 12, M: 32, L: 80, XL: 160 }, plat: { web: 1, movil: 1.3, escritorio: 1.1, ambas: 1.6 },
    extra: { roles: 16, admin: 24, notif: 8, pagos: 24, reporte: 8, integracion: 20, deploy: 12, docs: 8 }, diseno: 15, qa: 15, pm: 10, incert: { baja: 10, media: 20, alta: 30 }, idioma: 10, soporte: 0, horas_sem: 30 },
  msp: { salario: 0, tarifa: 0, nivel: { basico: 0, estandar: 0, premium: 0 }, servidor: { basico: 0, estandar: 0, premium: 0 }, red: 0, impresora: 0, sitio: 0, backup_tb: 0, m365: 0,
    onb_u: .5, onb_pc: .5, onb_s: 3, onb_base: 4 },
  libre: { salario: 0, tarifa: 0 } };
const PR_TRABAJOS = [['instalacion', '🏗'], ['desmontaje', '📦'], ['mudanza', '🚚'], ['reparacion', '🔧'], ['web', '🌐'], ['software', '💻'], ['msp', '🛡'], ['libre', '✏️']];
const PR_CAMPO = ['instalacion', 'desmontaje', 'mudanza'];   // trabajos en sitio (con plano, altura, cuadrilla)
const prTipo = d => d?.tipo || 'instalacion';
const prIc = tp => (PR_TRABAJOS.find(x => x[0] === tp) || ['', '📄'])[1];
const PR_GRUPOS = { desmontaje: [['g_prep', ['levantamiento', 'isp']], ['g_retirar', ['cables', 'soportes', 'conduit', 'ap', 'cam', 'acceso', 'tv', 'placas']], ['g_equipos', ['rack', 'rack_eq', 'pc', 'monitor', 'impresora', 'telefono']],
    ['g_reparar', ['plafones', 'firestop']], ['g_reciclar', ['rec_pc', 'rec_monitor', 'ups_bat', 'discos', 'viajes', 'contenedor', 'reporte']]],
  mudanza: [['g_mover', ['pc', 'monitor', 'impresora', 'telefono', 'tv', 'otros']], ['g_infra', ['servidor', 'rack_red', 'red_h', 'isp', 'viajes']]],
  reparacion: [['g_pc', ['diag', 'virus', 'os', 'datos', 'recuperacion', 'ssd', 'pieza', 'pantalla', 'limpieza']], ['g_imp', ['imp_mant', 'imp_rep', 'imp_cfg']], ['g_otros', ['servidor', 'red', 'correo', 'visitas']]] };
const prTT = (C, tp) => { const d = PR_TT[tp] || {}, c = jObj(jObj(C.tt)[tp]); const m = (a, b) => ({ ...(a || {}), ...jObj(b) });
  const it = (d.items || []).map(([k, h, f, fl]) => { const o = jObj(jObj(c.items)[k]); return [k, o.h ?? h, o.f ?? f, fl]; });
  const r = { ...d, ...c, items: it }; ['base', 'feat', 'tam', 'plat', 'extra', 'incert', 'nivel', 'servidor'].forEach(k => { if (d[k]) r[k] = m(d[k], c[k]); }); return r; };

// Cierra cualquier cálculo con equipos, materiales extra, cargos, contingencia e impuesto
function prFin(R, d, C, contPct){
  const eqs = jArr(d.equipos).filter(e => e.m && n0(e.qty)).map(e => ({ ...e, qty: n0(e.qty), p: n0(e.p), tot: n0(e.qty) * n0(e.p) }));
  const eqCosto = eqs.reduce((a, e) => a + e.tot, 0), eqVenta = eqCosto * (1 + n0(C.margen_eq) / 100);
  const mx = jArr(d.mat_extra).filter(m => m.d && n0(m.qty)).map(m => ({ k: '', d: m.d, qty: n0(m.qty), p: n0(m.p), u: 'u', tot: n0(m.qty) * n0(m.p) }));
  const mats = (R.mats || []).concat(mx), matSub = mats.reduce((a, m) => a + m.tot, 0), matMisc = R.mats ? matSub * n0(C.mat.misc) / 100 : 0;
  const matCosto = matSub + matMisc, matVenta = matCosto * (1 + n0(C.margen_mat) / 100);
  const cargos = R.cargos || [], cargosT = cargos.reduce((a, c) => a + c[1], 0);
  const conting = (R.mano + matVenta) * (contPct ?? n0(C.contingencia)) / 100;
  const costo = prCostoMO(R.total, d, C, prTipo(d)) + matCosto + eqCosto + cargosT * .8;
  const base$ = R.mano + matVenta + eqVenta + cargosT + conting, fm = prAjuste(base$, costo, d), margen$ = base$ * (fm - 1);
  const impuesto = (matVenta + eqVenta) * fm * n0(C.impuesto) / 100;
  const total$ = base$ + margen$ + impuesto;
  return { ...R, eqs, eqCosto, eqVenta, mats, matSub, matMisc, matCosto, matVenta, cargos, cargosT, conting, impuesto, total$, costo, ganancia: total$ - impuesto - costo, fm, margen$ };
}
const prCrew = (total, minP, d, C, maxDias = 10) => { const hd = n0(C.horas_dia) || 8, ef = n0(C.eficiencia) || .85, dc = p => total ? Math.ceil(total / (p * hd * ef)) : 0;
  let pers = n0(d.personas); if (!pers){ pers = minP; while (pers < 6 && dc(pers) > maxDias) pers++; }
  return { pers, dias: dc(pers), semanas: dc(pers) / 5, tablaP: [1, 2, 3, 4, 5, 6].filter(p => p >= minP).map(p => ({ p, dias: dc(p) })) }; };

function prCalcular(d, C = prConf()){
  d = prConPrecios(d, C); const tp = prTipo(d);
  if (tp === 'instalacion'){ const R = prCalcInst(d, n0(d.tarifa) ? { ...C, tarifa: n0(d.tarifa) } : C);
    R.tipo = tp; R.hl = [[t('pr_h_cable', { n: R.runs, f: R.corrida }), R.h.cable, 'cable'], [t('pr_h_mont'), R.h.montaje, 'montaje'], [t('pr_h_eq'), R.h.equipos, 'equipos'], [t('pr_h_survey'), R.h.survey, 'survey'], [t('pr_extra_h'), R.h.extra, 'extra'], [t('pr_h_pm', { p: C.t.pm }), R.h.pm, 'pm']].filter(x => x[1]);
    R.cargos = R.renta ? [[t('pr_renta_l', { l: t('prl.' + R.lift) }), R.renta]] : []; R.cargosT = R.renta; R.campo = true; return R; }
  const T = { ...prTT(C, tp), ...(n0(d.tarifa) ? { tarifa: n0(d.tarifa) } : {}) }, ap = d.aprendido || { f: 1, n: 0 }, s = { ...(d.sitio || {}) }, q = { ...(d.q || {}) };
  const fin = (x, cont) => prFin({ tipo: tp, ap, s, q, ...x }, d, C, cont);
  if (tp === 'desmontaje' || tp === 'mudanza' || tp === 'reparacion'){
    const alt = Math.max(6, n0(s.altura) || 10), fA = tp === 'desmontaje' ? escalon(C.f_alt, alt) : 1, fT = tp === 'desmontaje' ? (C.f_techo[s.techo] ?? 1) : 1, fD = C.f_dif[s.dificultad || 'normal'] ?? 1;
    const hl = [], cargos = []; let base = 0;
    T.items.forEach(([k, hu, fee, fl]) => { const n = n0(q[k]); if (!n) return; const h = n * hu * (fl === 'fa' ? fA * fT : 1) * fD; base += h;
      if (h) hl.push([`${t('pti.' + tp + '.' + k)} (${n})`, h, k]); if (fee) cargos.push([`${t('pti.' + tp + '.' + k)} × ${n}`, n * fee]); });
    if (n0(q.extra_h)){ base += n0(q.extra_h); hl.push([t('pr_extra_h'), n0(q.extra_h), 'extra']); }
    if (tp !== 'reparacion' && base){ const pm = base * n0(C.t.pm) / 100; hl.push([t('pr_h_pm', { p: C.t.pm }), pm, 'pm']); base += pm; }
    if (tp === 'reparacion' && base && base < 1){ hl.push([t('pr_minimo'), 1 - base]); base = 1; }
    const total = base * (ap.f || 1);
    const lift = tp === 'desmontaje' ? (alt > 30 ? 'boom' : alt > 20 ? 'tijera' : alt > 14 ? 'escalera_ext' : 'escalera') : null;
    const cw = tp === 'reparacion' ? { pers: 1, dias: Math.ceil(total / 7), semanas: Math.ceil(total / 7) / 5, tablaP: [] } : prCrew(total, tp === 'desmontaje' && alt > 14 ? 2 : (total > 16 ? 2 : 1), d, C);
    const renta = lift === 'tijera' || lift === 'boom' ? Math.max(1, Math.ceil(cw.semanas)) * n0(C.renta[lift]) : 0; if (renta) cargos.push([t('pr_renta_l', { l: t('prl.' + lift) }), renta]);
    const urg = tp === 'reparacion' ? ({ normal: 1, mismo_dia: 1.25, emergencia: 1.5 }[s.urgencia || 'normal'] || 1) : 1;
    const tarifa = n0(T.tarifa) * prHorario(s, C).f * urg;
    return fin({ hl, base, total, ...cw, minP: tp === 'desmontaje' && alt > 14 ? 2 : 1, lift, fA, fT, fD, tarifa, tarifaBase: T.tarifa, mano: total * tarifa, cargos, campo: tp !== 'reparacion' }, tp === 'reparacion' ? 0 : undefined);
  }
  if (tp === 'web'){
    const pag = Math.max(1, n0(q.paginas) || 1), idi = Math.max(1, n0(q.idiomas) || 1), hl = [];
    const add = (lbl, h) => { if (h) hl.push([lbl, h]); return h || 0; };
    let dev = add(t('pw_base.' + (s.tipo_sitio || 'corporativo')), n0(T.base[s.tipo_sitio || 'corporativo']));
    dev += add(t('pw_paginas', { n: pag }), pag * n0(T.pagina));
    Object.keys(T.feat).forEach(k => { if (q['f_' + k]) dev += add(t('pwf.' + k), n0(T.feat[k]) * (k === 'copy' || k === 'migracion' ? pag : 1)); });
    if (s.tipo_sitio === 'ecommerce' || n0(q.productos)){ dev += add(t('pw_productos', { n: n0(q.productos) }), n0(q.productos) * n0(T.producto)); if (q.f_pagos !== false) dev += add(t('pwf.pagos'), n0(T.pagos)); if (q.f_envios) dev += add(t('pwf.envios'), n0(T.envios)); }
    dev += add(t('pw_integ', { n: n0(q.integraciones) }), n0(q.integraciones) * n0(T.integracion));
    if (idi > 1) dev += add(t('pw_idiomas', { n: idi }), pag * n0(T.pagina) * (idi - 1) * n0(T.idioma) / 100 + (q.f_traduccion ? pag * 1 * (idi - 1) : 0));
    const rev = add(t('pw_rev', { n: n0(q.revisiones) || 2 }), dev * (n0(q.revisiones) || 2) * n0(T.revision) / 100);
    const pm = add(t('pr_h_pm', { p: T.pm }), (dev + rev) * n0(T.pm) / 100), qa = add(t('pw_qa', { p: T.qa }), (dev + rev) * n0(T.qa) / 100);
    if (n0(q.extra_h)) add(t('pr_extra_h'), n0(q.extra_h));
    const base = hl.reduce((a, x) => a + x[1], 0), total = base * (ap.f || 1), pers = Math.max(1, n0(d.personas) || 1), dias = Math.ceil(total / (pers * 6));
    const rec = []; if (q.r_hosting) rec.push([t('pwr.hosting'), n0(T.hosting), 'mes']); if (q.r_mant) rec.push([t('pwr.mant'), n0(T.mant), 'mes']); if (q.r_dominio) rec.push([t('pwr.dominio'), n0(T.dominio), 'anio']);
    return fin({ hl, base, total, pers, dias, semanas: dias / 5, tablaP: [1, 2, 3].map(p => ({ p, dias: Math.ceil(total / (p * 6)) })), minP: 1, tarifa: n0(T.tarifa), tarifaBase: T.tarifa, mano: total * n0(T.tarifa), rec }, 0);
  }
  if (tp === 'software'){
    const hl = [], mods = jArr(d.modulos).filter(m => m.n || m.t), plat = n0(T.plat[s.plataforma || 'web']) || 1;
    let dev = mods.reduce((a, m) => a + n0(T.tam[m.t || 'M']), 0) * plat; if (dev) hl.push([t('psw_mods', { n: mods.length, p: plat }), dev]);
    const E = T.extra, ex = (k, n = 1) => { const h = n0(E[k]) * n; if (h){ hl.push([t('pswe.' + k) + (n > 1 ? ` (${n})` : ''), h]); dev += h; } };
    if (q.x_roles) ex('roles'); if (q.x_admin) ex('admin'); if (q.x_notif) ex('notif'); if (q.x_pagos) ex('pagos'); ex('reporte', n0(q.reportes)); ex('integracion', n0(q.integraciones));
    if (n0(q.idiomas) > 1){ const h = dev * n0(T.idioma) / 100 * (n0(q.idiomas) - 1); hl.push([t('pw_idiomas', { n: n0(q.idiomas) }), h]); dev += h; }
    const pc = (k, lbl) => { const h = dev * n0(T[k]) / 100; if (h) hl.push([lbl, h]); return h; };
    const dis = pc('diseno', t('psw_dis', { p: T.diseno })), qa = pc('qa', t('pw_qa', { p: T.qa })), pm = pc('pm', t('pr_h_pm', { p: T.pm }));
    ex('deploy'); ex('docs'); if (n0(q.extra_h)){ hl.push([t('pr_extra_h'), n0(q.extra_h)]); dev += n0(q.extra_h); }
    const sub = dev + dis + qa + pm, inc = n0(T.incert[s.incertidumbre || 'media']), cont = sub * inc / 100; hl.push([t('psw_cont', { p: inc }), cont]);
    const base = sub + cont, total = base * (ap.f || 1), pers = Math.max(1, n0(d.personas) || 2), hs = n0(T.horas_sem) || 30, sem = total / (pers * hs);
    const mano = total * n0(T.tarifa), rec = q.r_soporte ? [[t('psw_soporte', { p: T.soporte }), mano * n0(T.soporte) / 100 / 12, 'mes']] : [];
    return fin({ hl, base, total, pers, dias: Math.ceil(sem * 5), semanas: sem, tablaP: [1, 2, 3, 4].map(p => ({ p, dias: Math.ceil(total / (p * hs) * 5) })), minP: 1, tarifa: n0(T.tarifa), tarifaBase: T.tarifa, mano, rec }, 0);
  }
  if (tp === 'msp'){
    const nv = s.nivel || 'estandar', hl = [], rec = [];
    const m = (lbl, n, p) => { if (n0(n) && p) rec.push([`${lbl} × ${n0(n)}`, n0(n) * p, 'mes']); };
    m(t('pms.usuarios'), q.usuarios, n0(T.nivel[nv])); m(t('pms.servidores'), q.servidores, n0(T.servidor[nv])); m(t('pms.red'), q.red, n0(T.red)); m(t('pms.impresoras'), q.impresoras, n0(T.impresora));
    m(t('pms.sitios'), Math.max(0, n0(q.sitios) - 1), n0(T.sitio)); m(t('pms.backup'), q.backup_tb, n0(T.backup_tb)); m(t('pms.m365'), q.m365, n0(T.m365));
    let onb = 0; if (q.onboarding !== false){ onb = n0(T.onb_base) + n0(q.usuarios) * n0(T.onb_u) + n0(q.pcs) * n0(T.onb_pc) + n0(q.servidores) * n0(T.onb_s); if (onb) hl.push([t('pms_onb'), onb]); }
    if (n0(q.extra_h)){ hl.push([t('pr_extra_h'), n0(q.extra_h)]); onb += n0(q.extra_h); }
    const total = onb * (ap.f || 1), dias = Math.ceil(total / 6);
    return fin({ hl, base: onb, total, pers: 1, dias, semanas: dias / 5, tablaP: [], minP: 1, tarifa: n0(T.tarifa), tarifaBase: T.tarifa, mano: total * n0(T.tarifa), rec, nivel: nv }, 0);
  }
  // libre: partidas a mano
  const pars = jArr(d.partidas).filter(p => p.d && n0(p.qty)), hl = [];
  let horas = 0, mano = 0; const cargos = [];
  pars.forEach(p => { const tot = n0(p.qty) * (n0(p.p) || (p.h ? n0(T.tarifa) : 0)); if (p.h){ horas += n0(p.qty); hl.push([p.d, n0(p.qty)]); mano += tot; } else cargos.push([p.d + (n0(p.qty) !== 1 ? ' × ' + n0(p.qty) : ''), tot]); });
  const dias = Math.ceil(horas / 7);
  return fin({ hl, base: horas, total: horas, pers: 1, dias, semanas: dias / 5, tablaP: [], minP: 1, tarifa: n0(T.tarifa), tarifaBase: T.tarifa, mano, cargos }, 0);
}


// ---------- FIN DEL MOTOR ----------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "método no permitido" }, 405);
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // 1) ¿Quién llama?
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quien, error: errUser } = await sb.auth.getUser(token);
    if (errUser || !quien?.user) return json({ error: "Sesión no válida. Vuelve a entrar." }, 401);

    // 2) Solo el Super admin y los operadores
    const { data: perfil } = await sb.from("perfiles").select("rol").eq("user_id", quien.user.id).maybeSingle();
    if (perfil?.rol !== "admin" && perfil?.rol !== "operador") return json({ error: "Sin permiso." }, 403);

    const b = await req.json().catch(() => ({}));
    if (!b.presupuesto_id) return json({ error: "Falta el presupuesto." }, 400);

    // 3) Todo se lee de la base
    const [p, cfg, priv, pv, cerrados] = await Promise.all([
      sb.from("presupuestos").select("*").eq("id", b.presupuesto_id).maybeSingle(),
      sb.from("presu_config").select("datos").eq("id", 1).maybeSingle(),
      sb.from("presu_config_priv").select("datos").eq("id", 1).maybeSingle(),
      sb.from("presupuesto_priv").select("datos").eq("presupuesto_id", b.presupuesto_id).maybeSingle(),
      sb.from("presupuestos").select("id,estado,datos,horas_est,horas_real").eq("estado", "completado"),
    ]);
    if (!p.data) return json({ error: "Presupuesto no encontrado." }, 404);
    if (priv.error || !priv.data) return json({ error: "Falta presu_config_priv." }, 500);

    // 4) Calcula (sin ningún await en medio: usa variables del motor)
    PRC = cfg.data; PRCP = priv.data; presus = cerrados.data || [];
    const d = prUnirDatos({ sitio: {}, q: {}, equipos: [], mat_extra: [], modo: "hora", ...jObj(p.data.datos) }, pv.data?.datos);
    PR = { id: p.data.id, d }; d.aprendido = prAprendido(d.sitio);
    const R = prCalcular(d), mensual = Math.round(jArr(R.rec).filter((r) => r[2] === "mes").reduce((a, r) => a + r[1], 0));
    const horas = +R.total.toFixed(2), semanas = +(R.semanas || 0).toFixed(2);

    // 5) Guarda: lo privado solo en la tabla del admin
    const up = await sb.from("presupuesto_priv").upsert({ presupuesto_id: p.data.id, totales: { total: Math.round(R.total$), mano: Math.round(R.mano), mensual } });
    if (up.error) return json({ error: up.error.message }, 500);
    if (p.data.estado !== "completado") {
      await sb.from("presupuestos").update({ horas_est: horas, totales: { ...jObj(p.data.totales), horas, personas: R.pers, dias: R.dias, semanas, factor: R.ap.f || 1 } }).eq("id", p.data.id);
    }

    // 6) Al operador: solo horas y lo que el admin ya liberó
    return json({ horas, personas: R.pers, dias: R.dias, semanas, total: p.data.total_liberado, mensual: p.data.mensual_liberado });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
