import { useTranslation } from 'react-i18next'

export function ParkingList({ names }: { names: readonly string[] }) {
  const { t } = useTranslation()
  if (names.length === 0) return <p>{t('parking.list.empty')}</p>
  return (
    <ul>
      {names.map((name) => <li key={name}>{name}</li>)}
    </ul>
  )
}
