SET session_replication_role = replica;

--
-- PostgreSQL database dump
--

-- \restrict kehfULUbBOeNenIuAeaEJrHhSQT5wdAbPYQHykXGo6NObWVHr5qP5i41YL8mdYI

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: tenants; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."tenants" ("tenant_id", "business_name", "status", "created_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	Khandakar Enterprise	active	2026-06-08 12:21:21.0286+00
\.


--
-- Data for Name: lpg_brands; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."lpg_brands" ("tenant_id", "brand_id", "brand_name", "description", "is_active", "created_at", "updated_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	0cd4e8a7-d1f8-421c-a34d-d1bddf2f37d3	Total Gas	\N	t	2026-06-08 16:09:48.350282+00	2026-06-08 16:09:48.350282+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	bad01a28-892b-498e-b6a9-5960de27ae90	Jamuna Gas	\N	t	2026-06-08 16:09:57.156556+00	2026-06-08 16:09:57.156556+00
\.


--
-- Data for Name: gas_plants; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."gas_plants" ("tenant_id", "plant_id", "plant_name", "brand_id", "location", "is_active", "created_at", "updated_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	Dhaka Plant	bad01a28-892b-498e-b6a9-5960de27ae90	mirpur dohs	t	2026-06-09 10:43:42.372694+00	2026-06-09 10:43:55.299535+00
\.


--
-- Data for Name: area_officers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."area_officers" ("tenant_id", "officer_id", "plant_id", "officer_name", "whatsapp_phone", "email", "created_at", "updated_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	1b1013ea-7203-4475-b821-266c7d573143	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	Mohshin	1234557788	khsiamsifat244@gmail.com	2026-06-09 10:54:23.098742+00	2026-06-09 10:54:23.098742+00
\.


--
-- Data for Name: audit_logs; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."audit_logs" ("tenant_id", "log_id", "table_name", "record_id", "action", "old_data", "new_data", "performed_by", "ip_address", "created_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	6c3b6d14-b239-4e45-bef4-b3f44f188c37	lpg_brands	0cd4e8a7-d1f8-421c-a34d-d1bddf2f37d3	INSERT	\N	{"brand_id": "0cd4e8a7-d1f8-421c-a34d-d1bddf2f37d3", "is_active": true, "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "brand_name": "Total Gas", "created_at": "2026-06-08T16:09:48.350282+00:00", "updated_at": "2026-06-08T16:09:48.350282+00:00", "description": null}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-08 16:09:48.350282+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	045e6aa9-5ac7-4df4-b736-8a8660079255	lpg_brands	bad01a28-892b-498e-b6a9-5960de27ae90	INSERT	\N	{"brand_id": "bad01a28-892b-498e-b6a9-5960de27ae90", "is_active": true, "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "brand_name": "Jamuna Gas", "created_at": "2026-06-08T16:09:57.156556+00:00", "updated_at": "2026-06-08T16:09:57.156556+00:00", "description": null}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-08 16:09:57.156556+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	ec15a252-3cde-49c4-a9e6-68039ea9a028	trucks	13386be2-1cb0-4eda-b544-6bc184fc33fd	INSERT	\N	{"name": "JAC", "size": "small", "capacity": 159, "truck_id": "13386be2-1cb0-4eda-b544-6bc184fc33fd", "is_active": true, "serial_no": "sdflksjflf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T09:07:56.888372+00:00", "updated_at": "2026-06-09T09:07:56.888372+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 09:07:56.888372+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	ae6e454d-4aef-42e6-baf0-55c68b3345a2	trucks	13386be2-1cb0-4eda-b544-6bc184fc33fd	UPDATE	{"name": "JAC", "size": "small", "status": "idle", "capacity": 159, "location": null, "truck_id": "13386be2-1cb0-4eda-b544-6bc184fc33fd", "is_active": true, "serial_no": "sdflksjflf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T09:07:56.888372+00:00", "updated_at": "2026-06-09T09:07:56.888372+00:00"}	{"name": "JAC", "size": "small", "status": "idle", "capacity": 159, "location": null, "truck_id": "13386be2-1cb0-4eda-b544-6bc184fc33fd", "is_active": true, "serial_no": "sdflksjflf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T09:07:56.888372+00:00", "updated_at": "2026-06-09T09:07:56.888372+00:00"}	\N	\N	2026-06-09 12:08:32.293614+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	c7202e79-1d83-4083-9c9c-34c7804c8dc6	trucks	13386be2-1cb0-4eda-b544-6bc184fc33fd	UPDATE	{"name": "JAC", "size": "small", "status": "idle", "capacity": 159, "location": null, "truck_id": "13386be2-1cb0-4eda-b544-6bc184fc33fd", "serial_no": "sdflksjflf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T09:07:56.888372+00:00", "updated_at": "2026-06-09T09:07:56.888372+00:00"}	{"name": "JAC", "size": "small", "status": "going", "capacity": 159, "location": null, "truck_id": "13386be2-1cb0-4eda-b544-6bc184fc33fd", "serial_no": "sdflksjflf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T09:07:56.888372+00:00", "updated_at": "2026-06-09T09:07:56.888372+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 13:19:42.300702+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	27c79079-36e9-4dd9-a866-6004d35a5236	trucks	b176499b-6e80-49eb-a63c-f29e484128f9	INSERT	\N	{"name": "ashok leyland", "size": "big", "status": "idle", "capacity": 585, "location": null, "truck_id": "b176499b-6e80-49eb-a63c-f29e484128f9", "serial_no": "dsfsfsdf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T14:52:10.085028+00:00", "updated_at": "2026-06-09T14:52:10.085028+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 14:52:10.085028+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	1407cb62-9186-4789-ac34-f77dba38ad32	trucks	b176499b-6e80-49eb-a63c-f29e484128f9	UPDATE	{"name": "ashok leyland", "size": "big", "status": "idle", "capacity": 585, "location": null, "truck_id": "b176499b-6e80-49eb-a63c-f29e484128f9", "serial_no": "dsfsfsdf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T14:52:10.085028+00:00", "updated_at": "2026-06-09T14:52:10.085028+00:00"}	{"name": "ashok leyland", "size": "big", "status": "going", "capacity": 585, "location": null, "truck_id": "b176499b-6e80-49eb-a63c-f29e484128f9", "serial_no": "dsfsfsdf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T14:52:10.085028+00:00", "updated_at": "2026-06-09T14:52:10.085028+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 14:53:34.95537+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	7eb4c673-629a-49ae-bfff-2f8735a8ea03	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	INSERT	\N	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:03:00.922975+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	84807cb0-6692-4b62-a050-16aa88cd9d43	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:03:20.776094+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	1dbdd173-5b1f-49a3-9c0e-3da2752e97ad	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:04:10.900467+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	44cefe7f-0040-4a55-ba58-6dda8b87dce7	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:04:23.337224+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	4cd505f6-be60-402d-b6a9-23c8947ea4f2	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:13:14.445146+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	e1d17e7f-0543-4285-a56c-23b611852e5a	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:13:56.078883+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	b616ed5f-e0a8-40e5-b641-720576b9662c	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:14:50.276174+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	9dfc276d-b65b-4118-8361-26489b0d2b07	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 15:26:10.733884+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	da18dc6c-9452-44a5-a7c4-a87259ff1a8a	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 16:44:16.242717+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	58e22855-47ce-4306-88ca-18dad25805c6	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 16:45:41.128299+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	54c264c3-9c20-4a21-8039-b06401833f72	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 16:48:06.708946+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	f391d294-21bc-4970-9a16-3ea8962a0082	trucks	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	UPDATE	{"name": "jac 2", "size": "small", "status": "idle", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	{"name": "jac 2", "size": "small", "status": "going", "capacity": 100, "location": null, "truck_id": "713dc9ef-4fc7-43ef-a649-0246f1a70a6c", "serial_no": "sdafasfaf", "tenant_id": "85787e44-a7be-4e2a-b268-e5a90de14bf2", "created_at": "2026-06-09T15:03:00.922975+00:00", "updated_at": "2026-06-09T15:03:00.922975+00:00"}	6d459eb2-989d-43ee-9f1d-8f283a9faa94	\N	2026-06-09 16:49:05.967643+00
\.


--
-- Data for Name: customers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."customers" ("tenant_id", "customer_id", "name", "tier", "shop_name", "phone", "address") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	7778893d-fb70-4275-99cf-212281066679	sadf sfdsaf asfs asd f	retail	\N	0190923232323	\N
85787e44-a7be-4e2a-b268-e5a90de14bf2	780493b7-b25a-43cc-bca0-03e9f4780311	Walk-in Customer	retail	\N	\N	\N
85787e44-a7be-4e2a-b268-e5a90de14bf2	6767fb72-cd80-435f-ba71-effd9e284a65	Walk-in Customer	retail	\N	\N	\N
85787e44-a7be-4e2a-b268-e5a90de14bf2	fcabe933-65c6-4fc8-a878-84e339f4b5f0	Walk-in Customer	retail	\N	00000000000	\N
85787e44-a7be-4e2a-b268-e5a90de14bf2	c69ec754-a6c0-40b7-90c0-86ace6e5937c	gfhdghdgh	wholesale	ghd gfh hdfghgh	65466463465	hdfgh dh
\.


--
-- Data for Name: user_profiles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."user_profiles" ("user_id", "tenant_id", "email", "is_active") FROM stdin;
6d459eb2-989d-43ee-9f1d-8f283a9faa94	85787e44-a7be-4e2a-b268-e5a90de14bf2	siamsifat244@gmail.com	t
\.


--
-- Data for Name: customer_transactions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."customer_transactions" ("tenant_id", "transaction_id", "customer_id", "type", "amount", "reference_id", "created_at", "created_by") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	3dc61e31-8ee0-4da1-91d9-ad80aa04b256	7778893d-fb70-4275-99cf-212281066679	invoice_charge	-60.00	89be1152-53e4-4179-ac5b-61be4986cddc	2026-06-09 19:41:16.739663+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	d1e5948a-d1ff-4beb-a5b4-e4b72deb8adf	7778893d-fb70-4275-99cf-212281066679	payment_receipt	60.00	89be1152-53e4-4179-ac5b-61be4986cddc	2026-06-09 19:41:16.739663+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	9a653799-f72d-46c0-b675-728eced65dea	7778893d-fb70-4275-99cf-212281066679	invoice_charge	-10.00	7f7aeb44-9263-4248-a919-b0b0ff577aee	2026-06-09 19:42:15.763418+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	5221a2e0-a19f-4a32-848d-751b5b18f340	7778893d-fb70-4275-99cf-212281066679	payment_receipt	10.00	7f7aeb44-9263-4248-a919-b0b0ff577aee	2026-06-09 19:42:15.763418+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	7dfc9275-2952-4e55-b479-53d739779fba	780493b7-b25a-43cc-bca0-03e9f4780311	invoice_charge	0.00	c0a9040b-4b5e-430f-ae64-0b3689666bb6	2026-06-10 04:28:51.916964+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	54132ee4-99f5-433e-8f32-218c4ea5e4cc	780493b7-b25a-43cc-bca0-03e9f4780311	payment_receipt	0.00	c0a9040b-4b5e-430f-ae64-0b3689666bb6	2026-06-10 04:28:51.916964+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	ae80533b-9f82-4b8f-9acf-4f6492aac3d8	6767fb72-cd80-435f-ba71-effd9e284a65	invoice_charge	0.00	d33fabaa-c3c7-4ef6-a957-fc31385edde9	2026-06-12 19:06:04.132087+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	a1350784-090b-4316-987a-8fd58cfcd501	6767fb72-cd80-435f-ba71-effd9e284a65	payment_receipt	0.00	d33fabaa-c3c7-4ef6-a957-fc31385edde9	2026-06-12 19:06:04.132087+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	bb4b430a-3cac-4791-b5e0-3a94fa673bed	fcabe933-65c6-4fc8-a878-84e339f4b5f0	invoice_charge	0.00	313d8149-f854-4850-8ae0-d1dbfb1859ee	2026-06-12 19:39:41.49309+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	288e11e6-a79d-4a90-9b92-0a552859e5a2	fcabe933-65c6-4fc8-a878-84e339f4b5f0	payment_receipt	0.00	313d8149-f854-4850-8ae0-d1dbfb1859ee	2026-06-12 19:39:41.49309+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	a6bd0dc3-87bd-4898-89cc-bf491d4702de	c69ec754-a6c0-40b7-90c0-86ace6e5937c	invoice_charge	-1010.00	b97facba-f25d-49c9-a870-442454e8be9d	2026-06-12 20:39:58.752832+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	3bc798b9-4199-4be1-9083-97f154a8de66	c69ec754-a6c0-40b7-90c0-86ace6e5937c	payment_receipt	1010.00	b97facba-f25d-49c9-a870-442454e8be9d	2026-06-12 20:39:58.752832+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	f5f64a6a-66fa-4cec-8cab-620271b15732	c69ec754-a6c0-40b7-90c0-86ace6e5937c	invoice_charge	0.00	dd8477b8-93ae-4f93-b27e-4695fc310833	2026-06-12 20:41:32.697095+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
85787e44-a7be-4e2a-b268-e5a90de14bf2	d5bc9edc-62aa-4e2e-a4f3-cc1dbb3e8bb8	c69ec754-a6c0-40b7-90c0-86ace6e5937c	payment_receipt	0.00	dd8477b8-93ae-4f93-b27e-4695fc310833	2026-06-12 20:41:32.697095+00	6d459eb2-989d-43ee-9f1d-8f283a9faa94
\.


--
-- Data for Name: items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."items" ("tenant_id", "item_id", "brand", "size_kg", "brand_id", "cylinder_weight", "mouth_size", "updated_at", "filled_quantity", "empty_quantity") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	104dae86-8464-427c-97e0-9c9241727654	Jamuna Gas	5.00	bad01a28-892b-498e-b6a9-5960de27ae90	\N	20mm	2026-06-10 04:28:51.916964+00	0	1
85787e44-a7be-4e2a-b268-e5a90de14bf2	69bdd70a-90ea-4798-bb4d-a4df20a7e1a7	Total Gas	12.00	0cd4e8a7-d1f8-421c-a34d-d1bddf2f37d3	\N	22mm	2026-06-12 20:39:58.752832+00	0	4
85787e44-a7be-4e2a-b268-e5a90de14bf2	803be5bf-e86d-4d94-b970-04217b57b926	Jamuna Gas	5.00	bad01a28-892b-498e-b6a9-5960de27ae90	\N	22mm	2026-06-12 20:41:32.697095+00	997	2
\.


--
-- Data for Name: inventory_movements; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."inventory_movements" ("tenant_id", "movement_id", "item_id", "movement_type", "reference_type", "reference_id", "created_by", "created_at", "notes", "filled_quantity_change", "empty_quantity_change") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	bf3b9e43-b6c5-4626-aa12-f536189c375f	803be5bf-e86d-4d94-b970-04217b57b926	purchase	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 17:02:56.093114+00	Received goods from Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	10	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	4af1a234-d6fc-4ff2-96ae-e4478e846744	803be5bf-e86d-4d94-b970-04217b57b926	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 19:41:16.739663+00	POS Sale 89be1152-53e4-4179-ac5b-61be4986cddc	-2	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	e08be30f-39d3-4c8f-97d8-783501d3339f	69bdd70a-90ea-4798-bb4d-a4df20a7e1a7	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 19:41:16.739663+00	POS Sale 89be1152-53e4-4179-ac5b-61be4986cddc	0	2
85787e44-a7be-4e2a-b268-e5a90de14bf2	19e75a26-03f9-4eb5-ad2a-593ea6d7a518	803be5bf-e86d-4d94-b970-04217b57b926	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 19:42:15.763418+00	POS Sale 7f7aeb44-9263-4248-a919-b0b0ff577aee	-1	-1
85787e44-a7be-4e2a-b268-e5a90de14bf2	16b010d4-7fe0-4b66-b9ae-1f12de69dfb4	803be5bf-e86d-4d94-b970-04217b57b926	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-10 04:28:51.916964+00	POS Sale c0a9040b-4b5e-430f-ae64-0b3689666bb6	-1	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	3361da16-8a36-4ac4-90ca-cf1857fbe24c	104dae86-8464-427c-97e0-9c9241727654	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-10 04:28:51.916964+00	POS Sale c0a9040b-4b5e-430f-ae64-0b3689666bb6	0	1
85787e44-a7be-4e2a-b268-e5a90de14bf2	f643fa2e-86c7-48dc-82ac-c5a354d30fd6	803be5bf-e86d-4d94-b970-04217b57b926	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:06:04.132087+00	POS Sale d33fabaa-c3c7-4ef6-a957-fc31385edde9	-1	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	951b4a8a-3fca-492f-8c55-cb808200485e	803be5bf-e86d-4d94-b970-04217b57b926	sale	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:06:04.132087+00	POS Sale d33fabaa-c3c7-4ef6-a957-fc31385edde9	0	1
85787e44-a7be-4e2a-b268-e5a90de14bf2	ee3d94bf-832e-4698-9443-ef2b7e97517e	803be5bf-e86d-4d94-b970-04217b57b926	sale	sale	313d8149-f854-4850-8ae0-d1dbfb1859ee	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:39:41.49309+00	POS Sale #313d8149	-1	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	5f22e49e-7ac9-4a59-aa8b-db0f1ae5ac22	803be5bf-e86d-4d94-b970-04217b57b926	sale	sale	313d8149-f854-4850-8ae0-d1dbfb1859ee	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:39:41.49309+00	POS Sale #313d8149	0	1
85787e44-a7be-4e2a-b268-e5a90de14bf2	ac6e0a65-ca7a-4eb2-9251-08f93ffe31ea	803be5bf-e86d-4d94-b970-04217b57b926	purchase	\N	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:40:35.871331+00	Received goods from Purchase 18e29c24-a6e9-4ea7-bf7e-214f7f009506	1000	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	31133c9c-ef55-447b-9a0b-4c1ac7f06bee	803be5bf-e86d-4d94-b970-04217b57b926	sale	sale	b97facba-f25d-49c9-a870-442454e8be9d	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 20:39:58.752832+00	POS Sale #b97facba	-2	0
85787e44-a7be-4e2a-b268-e5a90de14bf2	089954b2-f56a-4b13-948b-64467fb8bbe6	803be5bf-e86d-4d94-b970-04217b57b926	sale	sale	b97facba-f25d-49c9-a870-442454e8be9d	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 20:39:58.752832+00	POS Sale #b97facba	0	1
85787e44-a7be-4e2a-b268-e5a90de14bf2	e3361290-8af0-417e-b84d-ab4b38bc108f	69bdd70a-90ea-4798-bb4d-a4df20a7e1a7	sale	sale	b97facba-f25d-49c9-a870-442454e8be9d	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 20:39:58.752832+00	POS Sale #b97facba	0	1
85787e44-a7be-4e2a-b268-e5a90de14bf2	ee12725b-4022-44ea-9afd-f7b1b599c6f5	803be5bf-e86d-4d94-b970-04217b57b926	sale	sale	dd8477b8-93ae-4f93-b27e-4695fc310833	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 20:41:32.697095+00	POS Sale #dd8477b8	-1	-1
\.


--
-- Data for Name: permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."permissions" ("permission_id", "description") FROM stdin;
pos:sell	Can create a sales invoice at POS
pos:void	Can void/cancel a sales invoice
inventory:view	Can view inventory balances
inventory:adjust	Can create manual inventory adjustments
inventory:purchase	Can log a purchase / replenishment
customers:view	Can view customer list and details
customers:manage	Can create and edit customers
finance:view	Can view financial ledger and statements
finance:manage	Can record payments and credits
logistics:view	Can view trips and staff assignments
logistics:manage	Can create and complete delivery trips
settings:view	Can view system settings
settings:manage	Can modify roles, users, and system config
\.


--
-- Data for Name: price_books; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."price_books" ("tenant_id", "item_id", "customer_tier", "price", "effective_from", "effective_to") FROM stdin;
\.


--
-- Data for Name: trucks; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."trucks" ("tenant_id", "truck_id", "name", "serial_no", "capacity", "size", "created_at", "updated_at", "status", "location") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	13386be2-1cb0-4eda-b544-6bc184fc33fd	JAC	sdflksjflf	159	small	2026-06-09 09:07:56.888372+00	2026-06-09 09:07:56.888372+00	going	\N
85787e44-a7be-4e2a-b268-e5a90de14bf2	b176499b-6e80-49eb-a63c-f29e484128f9	ashok leyland	dsfsfsdf	585	big	2026-06-09 14:52:10.085028+00	2026-06-09 14:52:10.085028+00	going	\N
85787e44-a7be-4e2a-b268-e5a90de14bf2	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	jac 2	sdafasfaf	100	small	2026-06-09 15:03:00.922975+00	2026-06-09 15:03:00.922975+00	going	\N
\.


--
-- Data for Name: purchases; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."purchases" ("tenant_id", "purchase_id", "truck_id", "plant_id", "status", "transport_cost", "labour_cost", "total_cost", "notes", "created_by", "created_at", "updated_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	f2da11aa-613b-42d6-8ebb-5efc8cca3088	13386be2-1cb0-4eda-b544-6bc184fc33fd	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	in_transit	2000.00	100.00	1502100.00		6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 13:19:42.300702+00	2026-06-09 13:19:42.300702+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	200b3a40-ae24-4d21-8bad-98ef44180f39	b176499b-6e80-49eb-a63c-f29e484128f9	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	in_transit	0.00	0.00	129000.00		6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 14:53:34.95537+00	2026-06-09 14:53:34.95537+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	df566f8c-f4e9-4f62-a407-fdc25bdf168a	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	in_transit	0.00	0.00	5000.00		6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 15:03:20.776094+00	2026-06-09 15:03:20.776094+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	received	1000.00	100.00	11100.00		6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 16:45:41.128299+00	2026-06-09 17:02:56.093114+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	18e29c24-a6e9-4ea7-bf7e-214f7f009506	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	08256fa0-c37c-4b73-ae3d-34a7f6c88d22	received	5000.00	1200.00	228200.00		6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 15:26:10.733884+00	2026-06-12 19:40:35.871331+00
\.


--
-- Data for Name: purchase_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."purchase_items" ("tenant_id", "purchase_item_id", "purchase_id", "item_id", "type", "quantity", "unit_price", "line_total", "created_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	7dafec62-4eae-4056-b701-2b4f8df480a8	f2da11aa-613b-42d6-8ebb-5efc8cca3088	803be5bf-e86d-4d94-b970-04217b57b926	package	1000	1500.00	1500000.00	2026-06-09 13:19:42.300702+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	3fa27380-48d9-4636-ba45-140addd91257	200b3a40-ae24-4d21-8bad-98ef44180f39	803be5bf-e86d-4d94-b970-04217b57b926	package	100	1290.00	129000.00	2026-06-09 14:53:34.95537+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	dff68cbb-cd64-4815-a5a0-4ed463078ece	df566f8c-f4e9-4f62-a407-fdc25bdf168a	803be5bf-e86d-4d94-b970-04217b57b926	package	50	100.00	5000.00	2026-06-09 15:03:20.776094+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	cee59481-2846-49b5-b79c-4ff651f58019	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	803be5bf-e86d-4d94-b970-04217b57b926	package	10	1000.00	10000.00	2026-06-09 16:45:41.128299+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	4dc87b96-f57f-42f5-909a-47a926b2b5b5	18e29c24-a6e9-4ea7-bf7e-214f7f009506	803be5bf-e86d-4d94-b970-04217b57b926	package	1000	222.00	222000.00	2026-06-09 15:26:10.733884+00
\.


--
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."roles" ("tenant_id", "role_id", "name") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	Owner
\.


--
-- Data for Name: role_permissions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."role_permissions" ("tenant_id", "role_id", "permission_id") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	pos:sell
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	pos:void
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	inventory:view
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	inventory:adjust
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	inventory:purchase
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	customers:view
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	customers:manage
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	finance:view
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	finance:manage
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	logistics:view
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	logistics:manage
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	settings:view
85787e44-a7be-4e2a-b268-e5a90de14bf2	f8707037-bded-4c22-9f8d-6cfbd20d1f77	settings:manage
\.


--
-- Data for Name: sales; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."sales" ("tenant_id", "sale_id", "customer_id", "status", "subtotal", "discount_amount", "exchange_fee", "total_amount", "notes", "created_by", "created_at", "updated_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	89be1152-53e4-4179-ac5b-61be4986cddc	7778893d-fb70-4275-99cf-212281066679	completed	0.00	50.00	110.00	60.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 19:41:16.739663+00	2026-06-09 19:41:16.739663+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	7f7aeb44-9263-4248-a919-b0b0ff577aee	7778893d-fb70-4275-99cf-212281066679	completed	0.00	0.00	10.00	10.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-09 19:42:15.763418+00	2026-06-09 19:42:15.763418+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	c0a9040b-4b5e-430f-ae64-0b3689666bb6	780493b7-b25a-43cc-bca0-03e9f4780311	completed	0.00	0.00	0.00	0.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-10 04:28:51.916964+00	2026-06-10 04:28:51.916964+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	d33fabaa-c3c7-4ef6-a957-fc31385edde9	6767fb72-cd80-435f-ba71-effd9e284a65	completed	0.00	0.00	0.00	0.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:06:04.132087+00	2026-06-12 19:06:04.132087+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	313d8149-f854-4850-8ae0-d1dbfb1859ee	fcabe933-65c6-4fc8-a878-84e339f4b5f0	completed	0.00	0.00	0.00	0.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 19:39:41.49309+00	2026-06-12 19:39:41.49309+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	b97facba-f25d-49c9-a870-442454e8be9d	c69ec754-a6c0-40b7-90c0-86ace6e5937c	completed	0.00	100.00	1110.00	1010.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 20:39:58.752832+00	2026-06-12 20:39:58.752832+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	dd8477b8-93ae-4f93-b27e-4695fc310833	c69ec754-a6c0-40b7-90c0-86ace6e5937c	completed	0.00	0.00	0.00	0.00	\N	6d459eb2-989d-43ee-9f1d-8f283a9faa94	2026-06-12 20:41:32.697095+00	2026-06-12 20:41:32.697095+00
\.


--
-- Data for Name: sale_items; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."sale_items" ("tenant_id", "sale_item_id", "sale_id", "item_id", "type", "quantity", "unit_price", "line_total", "created_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	b6540c50-e4df-4100-89c2-561c9ff63066	89be1152-53e4-4179-ac5b-61be4986cddc	803be5bf-e86d-4d94-b970-04217b57b926	refill	2	0.00	0.00	2026-06-09 19:41:16.739663+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	8d1ab47e-4334-446f-9a19-bc0dd928fcda	89be1152-53e4-4179-ac5b-61be4986cddc	69bdd70a-90ea-4798-bb4d-a4df20a7e1a7	empty_return	2	0.00	0.00	2026-06-09 19:41:16.739663+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	3af156da-9128-4ee6-a329-c820f9f43dfe	7f7aeb44-9263-4248-a919-b0b0ff577aee	803be5bf-e86d-4d94-b970-04217b57b926	package	1	0.00	0.00	2026-06-09 19:42:15.763418+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	bc042fe7-fb2b-4398-b7d7-9a4623e9c615	c0a9040b-4b5e-430f-ae64-0b3689666bb6	803be5bf-e86d-4d94-b970-04217b57b926	refill	1	0.00	0.00	2026-06-10 04:28:51.916964+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	95eb0f2c-5854-45e7-a52a-48f46ad84249	c0a9040b-4b5e-430f-ae64-0b3689666bb6	104dae86-8464-427c-97e0-9c9241727654	empty_return	1	0.00	0.00	2026-06-10 04:28:51.916964+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	ca39ceae-c2ab-4289-b93b-46543d3f6f73	d33fabaa-c3c7-4ef6-a957-fc31385edde9	803be5bf-e86d-4d94-b970-04217b57b926	refill	1	0.00	0.00	2026-06-12 19:06:04.132087+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	21db5f92-c22f-4d9e-a4bc-560d782b97c8	d33fabaa-c3c7-4ef6-a957-fc31385edde9	803be5bf-e86d-4d94-b970-04217b57b926	empty_return	1	0.00	0.00	2026-06-12 19:06:04.132087+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	e197eb51-ce86-4d1a-8dd1-a430c004a558	313d8149-f854-4850-8ae0-d1dbfb1859ee	803be5bf-e86d-4d94-b970-04217b57b926	refill	1	0.00	0.00	2026-06-12 19:39:41.49309+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	e4b2d5b4-ff94-45c8-9dda-96c1f2bf3088	313d8149-f854-4850-8ae0-d1dbfb1859ee	803be5bf-e86d-4d94-b970-04217b57b926	empty_return	1	0.00	0.00	2026-06-12 19:39:41.49309+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	6c96fcb4-a569-495d-8688-2ad0eb2822fa	b97facba-f25d-49c9-a870-442454e8be9d	803be5bf-e86d-4d94-b970-04217b57b926	refill	2	0.00	0.00	2026-06-12 20:39:58.752832+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	23f783b7-579a-4f8c-8fef-cf8bdd48c1c9	b97facba-f25d-49c9-a870-442454e8be9d	803be5bf-e86d-4d94-b970-04217b57b926	empty_return	1	0.00	0.00	2026-06-12 20:39:58.752832+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	c49747c9-907f-4520-b7ef-411fe8eefda8	b97facba-f25d-49c9-a870-442454e8be9d	69bdd70a-90ea-4798-bb4d-a4df20a7e1a7	empty_return	1	0.00	0.00	2026-06-12 20:39:58.752832+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	6dc1ef60-d2e8-4bc1-9b41-aaa8d5607adb	dd8477b8-93ae-4f93-b27e-4695fc310833	803be5bf-e86d-4d94-b970-04217b57b926	package	1	0.00	0.00	2026-06-12 20:41:32.697095+00
\.


--
-- Data for Name: transits; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."transits" ("tenant_id", "transit_id", "truck_id", "purchase_id", "status", "driver_cost", "helper_cost", "oil_cost", "additional_costs", "total_cost", "created_at", "updated_at", "transport_fee") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	4062cc2a-3656-42ba-8364-59102ef2096d	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	df566f8c-f4e9-4f62-a407-fdc25bdf168a	completed	0.00	0.00	0.00	[]	0.00	2026-06-09 15:03:20.776094+00	2026-06-09 15:04:10.900467+00	0.00
85787e44-a7be-4e2a-b268-e5a90de14bf2	ec376b3b-503d-4894-ba3d-afe8e47007f9	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	\N	completed	0.00	0.00	0.00	[]	0.00	2026-06-09 15:04:23.337224+00	2026-06-09 15:13:14.445146+00	0.00
85787e44-a7be-4e2a-b268-e5a90de14bf2	e61df7be-a089-4867-9a57-8b013ac9ec42	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	\N	completed	100.00	100.00	200.00	[]	400.00	2026-06-09 15:13:56.078883+00	2026-06-09 15:14:50.276174+00	5000.00
85787e44-a7be-4e2a-b268-e5a90de14bf2	d4af873a-e06c-4a45-b4c9-93c7a18fb220	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	18e29c24-a6e9-4ea7-bf7e-214f7f009506	completed	0.00	0.00	0.00	[]	0.00	2026-06-09 15:26:10.733884+00	2026-06-09 16:44:16.242717+00	0.00
85787e44-a7be-4e2a-b268-e5a90de14bf2	45ec2ac4-658f-46ba-be15-d7ab59a82718	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	completed	500.00	200.00	100.00	[]	800.00	2026-06-09 16:45:41.128299+00	2026-06-09 16:48:06.708946+00	0.00
85787e44-a7be-4e2a-b268-e5a90de14bf2	ca465f78-1f46-4ba0-8133-59b38d12d43f	713dc9ef-4fc7-43ef-a649-0246f1a70a6c	\N	active	0.00	0.00	0.00	[]	0.00	2026-06-09 16:49:05.967643+00	2026-06-09 16:49:05.967643+00	2000.00
\.


--
-- Data for Name: user_roles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."user_roles" ("tenant_id", "user_id", "role_id") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	6d459eb2-989d-43ee-9f1d-8f283a9faa94	f8707037-bded-4c22-9f8d-6cfbd20d1f77
\.


--
-- Data for Name: wallets; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."wallets" ("tenant_id", "wallet_id", "type", "balance", "created_at", "updated_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	logistics	11800.00	2026-06-09 14:58:29.22156+00	2026-06-09 17:02:54.599901+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	590a927f-ff5e-4ae5-8210-68d2d70a848e	dealership	761710.00	2026-06-09 14:58:29.22156+00	2026-06-12 20:41:32.697095+00
\.


--
-- Data for Name: wallet_transactions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY "public"."wallet_transactions" ("tenant_id", "transaction_id", "wallet_id", "amount", "type", "reference_id", "description", "created_at") FROM stdin;
85787e44-a7be-4e2a-b268-e5a90de14bf2	45eaab68-e70d-4987-b522-e2cfa113f972	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	5000.00	transport_income	e61df7be-a089-4867-9a57-8b013ac9ec42	Fee for custom transit	2026-06-09 15:13:56.078883+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	b9cfcd8c-2516-4aeb-a782-6e5c40f9aba2	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	-400.00	transit_cost	e61df7be-a089-4867-9a57-8b013ac9ec42	Transit costs deduction upon completion	2026-06-09 15:14:50.276174+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	3103facd-c87c-455a-aa99-a0e7c973c17f	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	5000.00	transport_income	18e29c24-a6e9-4ea7-bf7e-214f7f009506	Transport fee for Purchase 18e29c24-a6e9-4ea7-bf7e-214f7f009506	2026-06-09 15:26:10.733884+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	54fb4af8-1e8f-40d8-8601-e518cd00fa7b	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	1000.00	transport_income_adj	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Transport fee adjustment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 16:46:28.261173+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	7b76c11a-8667-4f96-ba3f-dd18da8aa1e7	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	-800.00	transit_cost	45ec2ac4-658f-46ba-be15-d7ab59a82718	Transit costs deduction upon completion	2026-06-09 16:48:06.708946+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	dd68bb2e-a6f1-49b8-a1df-f54005cfdcad	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	2000.00	transport_income	ca465f78-1f46-4ba0-8133-59b38d12d43f	Fee for custom transit	2026-06-09 16:49:05.967643+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	acb0a6b9-f9a9-4bc5-a089-003106a44b4a	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	1000.00	transport_income_adj	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Transport fee adjustment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 16:57:01.524533+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	c1eaaaa6-5cbf-4f0c-9fb1-b7b6e4da67b1	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	-1500.00	transport_income_adj	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Transport fee adjustment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 16:57:13.563739+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	a20ece5a-7cf2-4617-91a5-2533a60e1cfc	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	500.00	transport_income_adj	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Transport fee adjustment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 16:57:31.125652+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	7ad408ef-2c5e-4a6f-afde-68eadcecf22d	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	1000.00	transport_income_adj	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Transport fee adjustment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 16:57:49.644102+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	86cf9f06-d0e0-49d9-8c5b-1c9ba38d487a	5298fea5-57d4-4d1a-91d7-52e4a7bf0677	-1000.00	transport_income_adj	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Transport fee adjustment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 17:02:54.599901+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	71aff58a-57a6-4805-a2cf-34e8e1ebff0c	590a927f-ff5e-4ae5-8210-68d2d70a848e	-11100.00	purchase_expense	890360b1-d759-4d5d-bc1d-cc13cd7fcf85	Payment for Purchase 890360b1-d759-4d5d-bc1d-cc13cd7fcf85	2026-06-09 17:02:56.093114+00
85787e44-a7be-4e2a-b268-e5a90de14bf2	7af56c5d-171b-45d3-b88c-71cf96de33ac	590a927f-ff5e-4ae5-8210-68d2d70a848e	-228200.00	purchase_expense	18e29c24-a6e9-4ea7-bf7e-214f7f009506	Payment for Purchase 18e29c24-a6e9-4ea7-bf7e-214f7f009506	2026-06-12 19:40:35.871331+00
\.


--
-- PostgreSQL database dump complete
--

-- \unrestrict kehfULUbBOeNenIuAeaEJrHhSQT5wdAbPYQHykXGo6NObWVHr5qP5i41YL8mdYI

RESET ALL;
