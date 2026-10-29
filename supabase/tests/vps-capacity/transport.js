import http from 'k6/http';
import { check } from 'k6';

const config=JSON.parse(open(__ENV.CONFIG));
export const options={
  scenarios:{connections:{executor:'per-vu-iterations',vus:Number(__ENV.USERS),iterations:1,maxDuration:'30s'}},
  thresholds:{http_req_failed:['rate==0'],checks:['rate==1'],http_req_duration:['p(99)<5000']},
  summaryTrendStats:['avg','med','p(95)','p(99)','max'],
  systemTags:['status','method','name','scenario','error_code','expected_response'],
  userAgent:'LPG-Capacity-Transport-Control/1.0',
};
export default function(){
  const response=http.get(config.url+'/auth/v1/health',{
    headers:{apikey:config.anon,Origin:config.worker},timeout:'10s',tags:{name:'transport_health'},
  });
  check(response,{'public health responds successfully':r=>r.status===200});
}
export function handleSummary(data){return{[__ENV.SUMMARY]:JSON.stringify(data,null,2)};}
