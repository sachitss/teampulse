import type { Db } from '@/lib/db';
import type { Option } from './person-form';

export async function managersAndTeams(d: Db): Promise<{ managers: Option[]; teams: Option[] }> {
  return {
    managers: await d.query<Option>(`select id, full_name as name from profiles where active and role in ('manager', 'admin', 'hr') order by full_name`),
    teams: await d.query<Option>(`select id, name from teams order by name`),
  };
}
