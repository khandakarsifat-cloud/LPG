-- Keep the replacement RPC under the same owner as the existing public workflows.
alter function public.transition_transit(uuid,text,integer,jsonb) owner to postgres;
