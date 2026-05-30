import http from "k6/http";

export const options = {
  vus: 1000,
  duration: "15m",
};

export default function () {
  http.get("http://HA_DNS/cpu");
}
