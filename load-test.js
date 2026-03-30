import http from 'k6/http';
import { sleep } from 'k6';

export default function () {
  http.get('http://20.198.122.246:32129');
  sleep(1);
}

#install k6
