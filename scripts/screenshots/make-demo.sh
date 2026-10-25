#!/bin/sh
set -e
rm -rf /tmp/projects; mkdir -p /tmp/projects/weather-api/src /tmp/projects/weather-api/test; cd /tmp/projects/weather-api
cat > package.json <<"EOF"
{
  "name": "weather-api",
  "version": "1.4.0",
  "type": "module",
  "scripts": { "build": "tsc", "test": "node --test test/" },
  "devDependencies": { "typescript": "^6.0.0" }
}
EOF
cat > tsconfig.json <<"EOF"
{
  "compilerOptions": { "strict": true, "target": "es2022", "module": "nodenext", "outDir": "dist" },
  "include": ["src"]
}
EOF
cat > src/units.ts <<"EOF"
/** Celsius to Fahrenheit, rounded to one decimal place. */
export function toFahrenheit(celsius: number): number {
  return Math.round((celsius * 9 / 5 + 32) * 10) / 10;
}

/** Metres per second to kilometres per hour. */
export function toKmh(metresPerSecond: number): number {
  return Math.round(metresPerSecond * 3.6);
}
EOF
cat > src/forecast.ts <<"EOF"
import { toFahrenheit, toKmh } from "./units.js";

export interface Reading {
  time: Date;
  temperature: number;
  windSpeed: number;
  rain: number;
}

/** A day's summary: the high, the low and whether to take an umbrella. */
export interface DaySummary {
  high: number;
  low: number;
  umbrella: boolean;
  windKmh: number;
}

/**
 * Summarises a day of readings.
 * @param readings Hourly readings, in any order.
 * @param fahrenheit Report temperatures in Fahrenheit.
 */
export function summarise(readings: Reading[], fahrenheit = false): DaySummary {
  const temperatures = readings.map((r) => r.temperature);
  const convert = (t: number) => (fahrenheit ? toFahrenheit(t) : t);
  return {
    high: convert(Math.max(...temperatures)),
    low: convert(Math.min(...temperatures)),
    umbrella: readings.some((r) => r.rain > 0.5),
    windKmh: toKmh(Math.max(...readings.map((r) => r.windSpeed))),
  };
}
EOF
cat > src/server.ts <<"EOF"
import { createServer } from "node:http";
import { summarise, type Reading } from "./forecast.js";

const port = Number(process.env.PORT ?? 8080);

async function fetchReadings(city: string): Promise<Reading[]> {
  const response = await fetch(`https://api.example.com/hourly?city=${encodeURIComponent(city)}`);
  return (await response.json()) as Reading[];
}

createServer(async (request, response) => {
  const city = new URL(request.url ?? "/", "http://localhost").searchParams.get("city") ?? "London";
  const summary = summarise(await fetchReadings(city), "yes");
  response.setHeader("Content-Type", "application/json");
  response.end(JSON.stringify({ city, ...summary }));
}).listen(port);

console.log(`weather-api listening on ${port}`);
EOF
cat > test/units.test.mjs <<"EOF"
import { test } from "node:test";
import assert from "node:assert/strict";

const toFahrenheit = (c) => Math.round((c * 9 / 5 + 32) * 10) / 10;
const toKmh = (ms) => Math.round(ms * 3.6);

test("freezing point", () => assert.equal(toFahrenheit(0), 32));
test("body temperature", () => assert.equal(toFahrenheit(37), 98.6));
test("gale force", () => assert.equal(toKmh(20), 72));
test("calm", () => assert.equal(toKmh(0), 0));
EOF
cat > README.md <<"EOF"
# weather-api

A tiny HTTP service that summarises a day of hourly weather readings.

```sh
npm install
npm run build && node dist/server.js
curl "localhost:8080/?city=Edinburgh"
```

## Response

| Field | Meaning |
|---|---|
| `high`, `low` | The day's temperatures (°C, or °F with `?units=f`) |
| `umbrella` | Whether any hour has more than 0.5 mm of rain |
| `windKmh` | The strongest wind, in km/h |

## To do

- [x] Fahrenheit
- [x] Wind speed
- [ ] Cache readings for ten minutes
EOF
printf "node_modules/\ndist/\n" > .gitignore
git init -q -b main; git config user.name "Sam Taylor"; git config user.email sam@example.com
c() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -qm "$2"; }
git add README.md package.json tsconfig.json .gitignore src/units.ts; c 2026-10-20T10:12:00 "Unit conversions"
git add src/forecast.ts; c 2026-10-21T14:40:00 "Summarise a day of readings"
git switch -qc feature/wind; git add test; c 2026-10-22T09:05:00 "Tests for unit conversions"
git switch -q main; GIT_AUTHOR_DATE=2026-10-23T16:20:00 GIT_COMMITTER_DATE=2026-10-23T16:20:00 git merge -q --no-ff feature/wind -m "Merge branch feature/wind"
git add src/server.ts; c 2026-10-24T11:30:00 "HTTP server"
sed -i "s|return Math.round(metresPerSecond \* 3.6);|return Math.round(metresPerSecond * 3.6 * 10) / 10;|" src/units.ts
printf -- "- [ ] Air quality\n" >> README.md
git log --oneline --graph; git status -sb
