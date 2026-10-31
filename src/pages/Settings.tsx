import { StoveProductTypes } from '../components/inventory/StoveInventory';
import { useState } from 'react';
import { Building2, Factory, Tags, Users, Weight, Palette, Moon, Sun } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useAppearance } from '../hooks/useAppearance';
import { useSaveBusinessProfile } from '../hooks/useBusinessSettings';
import { BrandManagement } from '../components/business/BrandManagement';
import { AttendanceSettings } from '../components/business/AttendanceSettings';
import { CatalogSettings } from '../components/business/CatalogSettings';
import '../components/business/settings.css';
import { VehicleExpenseCategories } from '../components/business/VehicleExpenseCategories';
import { SpendingCategories } from '../components/business/SpendingCategories';
import { GasPlantSettings } from '../components/business/GasPlantSettings';

type Section = 'stove-types' | 'vehicle-expenses' | 'business' | 'spending' | 'plants' | 'brands' | 'roles' | 'weights' | 'appearance';
const sections = [{id:'stove-types',label:'Stove product types',icon:Tags}, {id:'vehicle-expenses',label:'Vehicle expenses',icon:Tags}, {id:'spending',label:'Spending categories',icon:Tags}, { id: 'plants', label: 'Gas plants', icon: Factory }, { id: 'business', label: 'Business profile', icon: Building2 }, { id: 'brands', label: 'LPG brands', icon: Tags }, { id: 'roles', label: 'Employee roles', icon: Users }, { id: 'weights', label: 'Cylinder weights', icon: Weight }, { id: 'appearance', label: 'Appearance', icon: Palette }] as const;
export const SettingsPage = () => {
 const { can } = useAuth(); const manage = can('settings:manage'); const plants = can('gas_plants:view') || can('gas_plants:manage');
 const available = sections.filter(item => item.id === 'plants' ? plants : item.id === 'appearance' ? can('preferences:manage') : manage);
 const [section, setSection] = useState<Section>(manage ? 'business' : plants ? 'plants' : 'appearance');
 const selected = available.some(item => item.id === section) ? section : available[0]?.id;
 return <div className="settings-workspace"><p className="page-subtitle">Business configuration and your personal preferences.</p>
  <div className="settings-layout"><nav className="settings-navigation" aria-label="Settings sections">{available.map(item => <button key={item.id} aria-current={selected === item.id ? 'page' : undefined} onClick={() => setSection(item.id)}><item.icon size={16} aria-hidden="true" />{item.label}</button>)}</nav>
   <div className="settings-content" key={selected}>
    {selected === 'business' && <><BusinessProfile /><AttendanceSettings /></>}
    {selected === 'stove-types' && <StoveProductTypes />}
    {selected === 'vehicle-expenses' && <VehicleExpenseCategories/>}
    {selected === 'spending' && <SpendingCategories/>}
    {selected === 'plants' && <GasPlantSettings />}
    {selected === 'brands' && <section className="settings-section"><header className="settings-section-heading"><div><h2>LPG brands</h2><p>Your brand catalog and display order across inventory, sales and purchases.</p></div></header><BrandManagement /></section>}
    {selected === 'roles' && <CatalogSettings kind="role" />}{selected === 'weights' && <CatalogSettings kind="weight" />}
    {selected === 'appearance' && <Appearance />}
   </div>
  </div>
 </div>;
};
function BusinessProfile() {
 const { profile } = useAuth(); const [name, setName] = useState(profile?.business_name ?? ''); const save = useSaveBusinessProfile();
 return <section className="settings-section"><header className="settings-section-heading"><div><h2>Business profile</h2><p>Details shared with your team and shown on receipts.</p></div></header><form className="settings-card settings-profile-form" onSubmit={event => { event.preventDefault(); save.mutate(name); }}><label className="input-group"><span className="input-label">Business name</span><input className="input-field" required maxLength={255} value={name} onChange={event => setName(event.target.value)} /></label><button className="btn btn-primary" disabled={save.isPending || name.trim() === profile?.business_name}>Save profile</button>{save.isError && <p className="purchase-error" role="alert">{save.error.message}</p>}{save.isSuccess && <p role="status">Business profile saved.</p>}</form></section>;
}
function Appearance() {
 const { theme, query, save } = useAppearance();
 return <section className="settings-section"><header className="settings-section-heading"><div><h2>Appearance</h2><p>Your preference follows your account across devices.</p></div></header><div className="settings-card"><div className="settings-appearance-options" role="group" aria-label="Color theme">{([{ value: 'light', icon: Sun, label: 'Light' }, { value: 'dark', icon: Moon, label: 'Dark' }] as const).map(item => <button key={item.value} className="settings-theme-option" aria-pressed={theme === item.value} disabled={save.isPending || query.isPending} onClick={() => save.mutate(item.value)}><item.icon size={20} aria-hidden="true" /><strong>{item.label}</strong></button>)}</div>{(save.isError || query.isError) && <p role="alert" className="purchase-error">{save.error?.message ?? 'Appearance preferences unavailable.'}</p>}{save.isSuccess && <p role="status">Appearance saved.</p>}</div></section>;
}
