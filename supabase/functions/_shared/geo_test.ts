import { assert, assertAlmostEquals, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { allowedRadiusMeters, assertCoordinates, haversineMeters } from "./geo.ts";

const PAULISTA = { latitude: -23.561414, longitude: -46.655881 };

Deno.test("haversine: distância de um ponto para ele mesmo é zero", () => {
  assertAlmostEquals(haversineMeters(PAULISTA, PAULISTA), 0, 1e-6);
});

Deno.test("haversine: 0,01° de latitude ≈ 1,11 km", () => {
  const north = { latitude: PAULISTA.latitude + 0.01, longitude: PAULISTA.longitude };
  assertAlmostEquals(haversineMeters(PAULISTA, north), 1111, 5);
});

Deno.test("haversine: confere com distância conhecida São Paulo–Rio (~357 km)", () => {
  const rio = { latitude: -22.906847, longitude: -43.172896 };
  const distanceKm = haversineMeters(PAULISTA, rio) / 1000;
  assert(distanceKm > 355 && distanceKm < 365, `esperava ~357 km, obtive ${distanceKm}`);
});

Deno.test("haversine: é simétrica", () => {
  const other = { latitude: -23.55, longitude: -46.63 };
  assertAlmostEquals(
    haversineMeters(PAULISTA, other),
    haversineMeters(other, PAULISTA),
    1e-9,
  );
});

Deno.test("allowedRadius: sem GPS impreciso usa o raio da quadra", () => {
  assertEquals(allowedRadiusMeters(1000, 200, null), 1000);
  assertEquals(allowedRadiusMeters(1000, 200, 0), 1000);
});

Deno.test("allowedRadius: soma a imprecisão do GPS até o teto de tolerância", () => {
  assertEquals(allowedRadiusMeters(1000, 200, 50), 1050);
  assertEquals(allowedRadiusMeters(1000, 200, 500), 1200); // teto de +200 m
});

Deno.test("assertCoordinates: rejeita valores fora de faixa ou ausentes", () => {
  assertThrows(() => assertCoordinates({ latitude: 91, longitude: 0 }));
  assertThrows(() => assertCoordinates({ latitude: 0, longitude: 181 }));
  assertThrows(() => assertCoordinates({ latitude: Number.NaN, longitude: 0 }));
  assertThrows(() => assertCoordinates({ longitude: 10 }));
  assertEquals(assertCoordinates(PAULISTA), PAULISTA);
});
